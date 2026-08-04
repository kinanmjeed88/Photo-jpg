## 2024-05-24 - Document Scanner PII Leakage via Screenshots
**Vulnerability:** The application handles highly sensitive PII documents (passports, national IDs) but allows OS-level screen capture and displays plain document content in the Android Recents app switcher.
**Learning:** Apps handling physical document scans are essentially building a digital wallet. OS-level background snapshotting and user screenshots pose a significant data exfiltration risk.
**Prevention:** Apply WindowManager.LayoutParams.FLAG_SECURE in MainActivity.onCreate() to prevent screenshots, screen recording, and obscure the app in the recent apps list.
