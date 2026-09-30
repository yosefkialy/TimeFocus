# On-device sentence encoder (`FocusTransformer`)

Pure Swift + Accelerate inference for **`intfloat/multilingual-e5-small`** (BERT, 12 layers, 384-d,
XLM-R SentencePiece-Unigram vocabulary of 250k pieces, Hebrew + English + ~100 other languages).
There are no external packages, no Python and no network access at runtime.

```swift
let dir = URL(fileURLWithPath: ".../Application Support/TimeFocus/Models/multilingual-e5-small")
let encoder = try SentenceEncoder(directory: dir)           // ~0.4 s
let v = try encoder.encode(["query: main.swift — time_focus"])  // [[Float]] (384-d, unit length)
let ids = encoder.tokenize("query: שלום")                   // [0, …, 2]
```

The model directory needs `config.json`, `model.safetensors` and `tokenizer.json`
(`SentenceEncoderFiles.required`). The caller adds e5's `"query: "` / `"passage: "` prefix.
`paraphrase-multilingual-MiniLM-L12-v2` loads unchanged (it was verified too, see below).

## Architecture

| File | Role |
|---|---|
| `SentenceEncoder.swift` | Public API. Tokenises, splits very large batches into forward passes of ≤ 4096 tokens, and pools. |
| `UnigramTokenizer.swift` | `tokenizer.json` pipeline: added tokens, pre-tokenizer, Unigram model (byte trie + Viterbi), post-processor. |
| `SentencePieceNormalizer.swift` | Port of the SentencePiece *precompiled charsmap* (darts-clone double-array trie), plus the Replace/Strip/NFKC/… normalizers. |
| `BertModel.swift` | Weight loading (name-prefix tolerant) and the forward pass. |
| `Kernels.swift` | `cblas_sgemm` wrapper, LayerNorm, softmax, GELU, parallel-for. |
| `Safetensors.swift` | Header parser, `mmap` of the file, F32/F16/BF16/F64 → F32 conversion, `FloatBuffer`. |
| `BertConfig.swift` | `config.json` parser. |

**Forward pass (post-LN BERT, fp32).** The embeddings are `word[id] + position[i] + token_type[0]`,
followed by LayerNorm (eps from the config, 1e-12). Position ids start at 0 for `model_type: bert`, which
the reference confirms; RoBERTa-family configs start at `pad_token_id + 1`. Each of the 12 layers then
runs:

1. Fused Q|K|V projection as one GEMM.
2. Per-head `softmax(QKᵀ/√32)·V` on strided views.
3. Output dense + residual + LayerNorm.
4. 384→1536 GELU(erf) →384 + residual + LayerNorm.

Finally the last hidden state is mean-pooled over the attention mask and L2-normalised.
Every linear layer and both attention products use `cblas_sgemm` (AMX). Softmax, LayerNorm and bias
adds use vDSP/vForce. GELU uses a SIMD rational erf approximation (the Cephes-derived one also used by
XLA and Eigen), with max |erf error| 3.3e-7. That is ~7× faster than `simd.erf` and about as accurate as
PyTorch's own vectorised CPU erf.

**Batching.** Sequences are *packed*: all real tokens of the batch form one `[T, 384]` matrix for the
dense layers, and attention runs per sequence, so there is no padding and no mask. This is numerically
equivalent to padding to the longest sequence and masking padded keys with −∞, but spends no FLOPs on
padding. A text's embedding does not depend on what it is batched with; batched vs alone agree to a
cosine of ≥ 0.9999998. For big batches, attention (per sequence and head), GELU and LayerNorm are
spread over the cores with `DispatchQueue.concurrentPerform`. They inherit the caller's QoS.

**Memory.**

- `model.safetensors` is memory-mapped. The 250037×384 word-embedding matrix (384 MB) is never copied:
  rows are gathered straight from the mapping, so only touched 16 KB pages become resident.
- The ~85 MB of transformer weights are read with `pread` into owned buffers, so they are not counted
  twice.
- Activations are allocated per call. Buffers of 1 MB or more come from anonymous `mmap`/`munmap`, so
  the ~35 MB of scratch for a 16×128 batch goes back to the OS afterwards.
- `approximateMemoryBytes` = owned weights + tokenizer tables + embedding pages touched so far.
- An instance is immutable after `init`; the only shared mutable state is the page counter, which is
  lock-protected. Concurrent `encode` calls are safe (tested), but serialising them bounds peak memory.

## Tokenization

The module implements exactly what `tokenizer.json` declares, in the same order as the Rust
`tokenizers` library:

1. **Added tokens.** `<s> <pad> </s> <unk> <mask>` are cut out of the raw text with leftmost-longest
   matching, honouring `lstrip`/`rstrip`/`single_word`/`normalized`.
2. **Normalizer** (per remaining segment):
   - `Precompiled`: XLM-R's `nmt_nfkc` charsmap (NFKC, plus mapping odd whitespace to a space and
     removing control and zero-width characters). It is a faithful port of HF's `spm_precompiled`
     algorithm: the text is walked by extended grapheme cluster. A cluster shorter than 6 bytes is
     looked up whole, taking the *first* (shortest) trie match as the Rust code does; otherwise each
     scalar is looked up. So no NFKC approximation is involved.
   - `Replace(" {2,}" → " ")`.
3. **Pre-tokenizer: Metaspace.** `" "` becomes `"▁"`, a `"▁"` is prepended (prepend scheme `always`,
   i.e. legacy `add_prefix_space`), and the text is split before every `"▁"`. `WhitespaceSplit` and
   `Sequence` are also supported (MiniLM uses them).
4. **Unigram.** Viterbi best path over the vocabulary log-probs (f64, same tie-breaking as the Rust
   code). Unknown characters score `min_score − 10`, consecutive unknowns fuse into one `<unk>`, and
   `byte_fallback` is supported. The byte trie has 783k nodes (~9 MB).
5. **Post-processor.** The template `<s> $A </s>`. Truncation is on the right: `maxTokens` includes the
   2 special tokens. The file's own `truncation`/`padding` sections are ignored.

## Verification

The reference is HF `tokenizers` 0.23.2 (`Tokenizer.from_file`) and PyTorch 2.14 / transformers 5.17
`BertModel` in float32 with the same mean pooling and normalisation, all with the `"query: "` prefix.
The test set has 32 strings: English, Hebrew, Hebrew with niqqud, mixed He/En, Cyrillic, CJK, Arabic,
Thai/Devanagari/Hangul, URLs, code, window titles, emoji/ZWJ/flags, full-width and other
NFKC-sensitive characters, NFD accents, repeated spaces/tabs/newlines, zero-width and control
characters, literal `<s>`/`<mask>` in text, the empty string, and a 307-token paragraph truncated to 128.

| Check | e5-small | MiniLM-L12-v2 |
|---|---|---|
| Token ids exact (32 strings) | **32/32** | **32/32** |
| Truncated to 128 exact | 32/32 | 32/32 |
| Min cosine (Swift vs PyTorch) | **0.9999999971** | 0.9999999951 |
| Max abs element difference | 3.5e-7 | 5.0e-7 |
| Tokenizer stress test (163k strings\*) | 163,255/163,255 | 163,265/163,265 |

\* The stress set has every BMP code point in context, math-alphanumeric/emoji/CJK-compat/tag
characters, 30k random base+combining-mark clusters (Hebrew niqqud, Arabic harakat, Devanagari,
variation selectors, skin tones), 5k Hangul jamo sequences, 30k random mixes of whitespace, controls,
special tokens and scripts, 10k dictionary sentences, 15k source-code lines, and whitespace edge cases.
The one reported difference (a lone U+FEFF) was an artefact of the test loader: `JSONSerialization`
strips a leading BOM. The same string as a Swift literal matches HF (`[0, 6, 2]`).

Also checked:

- Tensor names with the `0.auto_model.` prefix and `LayerNorm.gamma/beta` give identical results.
- An F16 copy of the checkpoint gives bit-identical embeddings; all e5-small weights are exactly
  fp16-representable.
- A BF16 copy gives cosine ≥ 0.99997.

`EncoderCheck` re-runs a subset against embedded expected values. It checks exact ids for 10 strings,
truncation, 8 dims plus full-vector cosine for 3 strings, batch/alone consistency, and two semantic
checks, e.g. cos(EN "linear algebra eigenvalues", HE "אלגברה לינארית ערכים עצמיים") = 0.826 >
cos(EN, "funny cat videos") = 0.750. It then prints timings and memory:

```
scripts/build.sh EncoderCheck && .build-swiftc/bin/EncoderCheck [modelDir]   # exit status 0 = PASS
```

## Performance and memory (Apple M3, 8 GB, macOS 27, `-O -wmo`)

| Workload | Time |
|---|---|
| Load (config + 17 MB tokenizer.json + weights) | 0.38–0.43 s |
| Single text, 21–26 tokens | **3.5–3.8 ms** (target < 20 ms) |
| 16 window titles, ~15 tokens each | 14–16 ms |
| 4 × 128 tokens | 25–31 ms |
| 16 × 128 tokens | **106–133 ms**, ~16–19k tokens/s (target < 600 ms; PyTorch CPU on the same machine: 124 ms) |
| Tokenize a 128-token text | ~68 µs |
| Tokenize a 0.5 MB text (maxTokens 512) | ~20 ms (normalisation is linear in input length) |

Timing ranges come from runs made while other builds were loading the machine.

| Memory | |
|---|---|
| Process footprint after load | ~109 MB (85 MB weights + ~11 MB tokenizer + runtime) |
| Footprint after a 16×128 batch | ~115 MB (scratch is returned to the OS) |
| Peak RSS | 121–131 MB after load; 150–167 MB after 16×128 batches (JSON parsing and batch scratch are transient) |
| `approximateMemoryBytes` | ~92–98 MB |
| Word-embedding mapping | 384 MB virtual; only touched pages are resident |

## Known limitations

- Supports only BERT/RoBERTa-family encoders with absolute positions and Unigram tokenizers. WordPiece
  and BPE models throw `EncoderError.unsupported`. Token type ids are always 0 (single-sentence input).
- The transformers **5.x** `AutoTokenizer` rebuilds the XLM-R pipeline in code, differently from
  `tokenizer.json`. It drops the trailing `"▁"` for text ending in whitespace and the `"▁"` before
  inline special tokens. This module follows `tokenizer.json`, i.e. the `tokenizers` library and
  transformers 4.x, which the model was published with. The only difference is one token on such
  inputs.
- The GELU erf approximation gives max |Δ| ≤ 9e-7 per activation. It is included in the verified
  cosines above.
- Grapheme clusters come from Swift's Unicode tables, not Rust's `unicode-segmentation`. A future
  Unicode-version mismatch could change clusters in exotic scripts. None were seen in the stress test.
- `single_word` added tokens use an approximation of regex `\w`, and Replace regexes use ICU instead of
  Oniguruma. Neither matters for e5 or MiniLM.
- The tokenizer normalises the whole text before truncating (linear time, about 40 ns/byte). Callers
  may want to pre-trim multi-megabyte inputs.
- Option: e5-small's weights are exactly fp16-representable. A losslessly converted F16
  `model.safetensors` (235 MB instead of 470 MB, halving the mapped embedding table) would load
  unchanged and give bit-identical results.
