import Foundation
import FocusML

/// Zero-shot "semantic anchors": bilingual descriptions of generic kinds of computer activity, embedded with the
/// same transformer as the user's windows. Each window gets a soft profile over these kinds, which pulls windows
/// of the same KIND together across different apps and ever-changing content — no LLM required.
public enum CategoryAnchors {
    public static let descriptions: [String] = [
        "Programming and software development: writing code, debugging, terminal commands, GitHub pull requests, Stack Overflow, API documentation. תכנות ופיתוח תוכנה",
        "Studying and coursework: university lectures, course material, homework exercises, exams, learning a subject. לימודים, הרצאה, תרגיל, קורס, מבחן",
        "Reading and research: articles, scientific papers, documentation, Wikipedia, background reading. קריאה ומחקר, מאמרים",
        "Email: inbox, reading and replying to emails, newsletters. דואר אלקטרוני ומיילים",
        "Chat and messaging with friends, family or colleagues: WhatsApp, Slack, Telegram, Messages. הודעות וצ'אט",
        "Video calls and online meetings: Zoom, Google Meet, Microsoft Teams. פגישות ושיחות וידאו",
        "Planning and project management: tasks, tickets, sprint boards, calendar, Jira, Notion, to-do lists. תכנון וניהול משימות ופרויקטים",
        "Writing documents and notes: Word, Google Docs, Pages, reports, notes. כתיבת מסמכים וסיכומים",
        "Design and creative work: Figma, Photoshop, illustration, video and photo editing. עיצוב ועבודה יצירתית",
        "Spreadsheets and data analysis: Excel, Google Sheets, tables, charts, dashboards. גיליונות אלקטרוניים וניתוח נתונים",
        "Finance and personal admin: online banking, bills, taxes, insurance, government forms. בנק, חשבונות, בירוקרטיה",
        "Online shopping: products, shopping cart, prices, orders, deals and coupons. קניות אונליין",
        "Reading news: headlines, breaking news, politics, economy, sports news. אתרי חדשות ומבזקים",
        "Social media feeds: Facebook, Instagram, TikTok, X/Twitter, Reddit, likes, comments and reels. רשתות חברתיות ופיד",
        "Watching videos and entertainment: YouTube videos, Netflix, movies, TV series, funny clips. צפייה בסרטונים, סדרות ובידור",
        "Listening to music and podcasts: Spotify, Apple Music, playlists. מוזיקה ופודקאסטים",
        "Playing video games and gaming. משחקי מחשב",
        "System settings, files and utilities: Finder, System Settings, installing apps, file management. הגדרות מערכת וקבצים",
    ]

    static func key(_ model: String) -> String { "anchors.\(model).v1" }

    /// Anchor embeddings for the given provider (cached per model in the database).
    static func embeddings(provider: EmbeddingProvider, store: Store) throws -> [[Float]] {
        if let cached = store.codable(key(provider.modelID), as: [[Float]].self), cached.count == descriptions.count,
           cached.first?.count == provider.dimension {
            return cached
        }
        var out: [[Float]] = []
        for chunk in descriptions.chunked(into: 8) { out += try provider.embed(chunk) }
        try store.setCodable(key(provider.modelID), out)
        return out
    }

    /// Per-anchor mean/std of similarities over the user's own corpus. Raw transformer similarities are all
    /// close together (e.g. 0.78–0.83); calibrating each anchor against the corpus ("contextual calibration")
    /// turns them into sharp, comparable evidence.
    public struct Calibration: Codable, Equatable {
        public var mean: [Float]
        public var std: [Float]
    }

    public static func calibrate(_ embeddings: [[Float]], anchors: [[Float]]) -> Calibration? {
        guard !anchors.isEmpty, embeddings.count >= 5 else { return nil }
        let d = anchors[0].count
        let valid = embeddings.filter { $0.count == d }
        guard valid.count >= 5 else { return nil }
        var mean = [Float](repeating: 0, count: anchors.count), sq = mean
        for e in valid {
            for (j, a) in anchors.enumerated() {
                let s = LA.dot(e, a)
                mean[j] += s
                sq[j] += s * s
            }
        }
        let n = Float(valid.count)
        for j in anchors.indices {
            mean[j] /= n
            sq[j] = max((sq[j] / n - mean[j] * mean[j]).squareRoot(), 0.01)
        }
        return Calibration(mean: mean, std: sq)
    }

    /// Soft category profile of one embedding: softmax over calibrated anchor similarities.
    public static func profile(_ embedding: [Float], anchors: [[Float]], calibration: Calibration?, temperature: Float = 0.6) -> [Float]? {
        guard !anchors.isEmpty, embedding.count == anchors[0].count else { return nil }
        var z = anchors.map { LA.dot(embedding, $0) }
        if let c = calibration, c.mean.count == z.count {
            for j in z.indices { z[j] = (z[j] - c.mean[j]) / c.std[j] }
            return LA.softmaxed(z, temperature: temperature)
        }
        return LA.softmaxed(z, temperature: 0.02)
    }
}
