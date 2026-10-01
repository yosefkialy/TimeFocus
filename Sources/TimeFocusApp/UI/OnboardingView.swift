import Combine
import FocusCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    var onFinish: () -> Void
    @ViewState private var step = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Capsule().fill(i <= step ? Theme.accent : Color.primary.opacity(0.12)).frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 20)
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: models
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            HStack {
                if step > 0 { Button("חזרה") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button(step == 1 && !model.hasAccessibility ? "המשך בלי הרשאה" : "המשך") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("בוא נתחיל") {
                        model.updateSettings { $0.onboardingCompleted = true }
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 600)
        .onReceive(timer) { _ in model.refreshEnvironment() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "scope").font(.system(size: 54, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("TimeFocus").font(.system(size: 34, weight: .bold))
            Text("עוזר מיקוד חכם שלומד את סוגי הפעילות שלך במחשב — ועוזר לך להישאר עליהם.").font(.title3)
            VStack(alignment: .leading, spacing: 10) {
                row("brain.head.profile", "לומד לבד", "בימים הראשונים הוא רק מתבונן ומקבץ את הפעילות שלך לסוגים בעזרת רשתות נוירונים.")
                row("calendar", "אתה מתכנן", "בכל יום בוחרים על אילו סוגי פעילות מתמקדים — לכל היום או לפי שעות.")
                row("tortoise.fill", "הוא עוזר לך לחזור", "סטית? תזכורת עדינה, ואם ממשיכים — היישום המסיח מואט בהדרגה.")
                row("lock.shield", "פרטי לגמרי", "הכל רץ ונשמר על המחשב הזה. שום מידע לא יוצא ממנו.")
            }
            .padding(.top, 6)
        }
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("הרשאות").font(.title.bold())
            Text("macOS דורש שתאשר בעצמך. ההרשאות משמשות רק לזיהוי הפעילות — המידע לא עוזב את המחשב.")
                .foregroundStyle(.secondary)
            PermissionRow(title: "נגישות (חובה)", detail: "קריאת היישום והחלון הפעילים, כתובת האתר והטקסט הגלוי. מסמנים את TimeFocus ב: הגדרות מערכת ← פרטיות ואבטחה ← נגישות.",
                          granted: model.hasAccessibility,
                          action: { Permissions.promptAccessibility(); Permissions.openSettings(.accessibility) })
            PermissionRow(title: "התראות (מומלץ)", detail: "תזכורות לחזור למיקוד, עם כפתורי פעולה מהירים.",
                          granted: model.notificationsAuthorized,
                          action: { model.notifications.requestAuthorization { ok in DispatchQueue.main.async { model.notificationsAuthorized = ok } } })
            PermissionRow(title: "הקלטת מסך (אופציונלי)", detail: "רק לזיהוי טקסט (OCR) — מפעילים בהגדרות. עוזר להבין תוכן שאין לו טקסט נגיש (PDF, שקפים בווידאו, תמונות), גם בעברית.",
                          granted: model.hasScreenRecording,
                          action: { Permissions.requestScreenRecording(); Permissions.openSettings(.screenRecording) })
            Text("טיפ: אחרי מתן הרשאת נגישות ייתכן שיהיה צורך לסגור ולפתוח את TimeFocus מחדש.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("מודלים מקומיים").font(.title.bold())
            Text("כדי להבין את המשמעות של מה שעל המסך (גם בעברית), TimeFocus משתמש במודלים בקוד פתוח שרצים על המחשב — ורק כשהוא פנוי.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ModelCatalog.embeddingModels.filter(\.recommended)) { m in
                ModelRow(model: m, selected: true, onSelect: {})
            }
            Divider()
            Text("אופציונלי: מודל שפה שמתאר כל פעילות במילים ומציע שמות לסוגי הפעילות (דורש llama.cpp — אפשר להתקין ממסך \"למידה ומודלים\").")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: model.appleIntelligence.available ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(model.appleIntelligence.available ? Theme.focusGreen : .secondary)
                Text(model.appleIntelligence.available ? "Apple Intelligence זמין וישמש אוטומטית." : "Apple Intelligence: \(model.appleIntelligence.reason)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 50)).foregroundStyle(Theme.focusGreen)
            Text("הכל מוכן").font(.title.bold())
            Text("TimeFocus מתחיל ללמוד עכשיו. פשוט תעבוד כרגיל. בעוד כ-\(model.settings.minLearningDays) ימים תקבל הודעה שהגיע הזמן לתת שמות לסוגי הפעילות שהתגלו, ומאז תוכל לבחור כל יום על מה להתמקד.")
                .fixedSize(horizontal: false, vertical: true)
            Text("האייקון בשורת התפריטים (🎯) מראה בכל רגע את המצב. בחירום: ⌃⌥⌘. מבטל מיד כל האטה.")
                .foregroundStyle(.secondary)
        }
    }
}
