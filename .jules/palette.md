> **⚠️ وثيقة تاريخية (Superseded):** يصف هذا الملف مراجعة/بنية إصدار سابق من التطبيق
> ولم يعد مطابقاً للكود الحالي. التقرير المعتمد والحديث هو
> [`docs/AUDIT_REPORT_AR.md`](../docs/AUDIT_REPORT_AR.md).
> تم الاحتفاظ به للمرجعية التاريخية فقط.

## 2024-06-25 - Destructive Action Confirmation in Transient Data Context
**Learning:** The scanner screen had a delete button on newly captured images without confirmation. Because these images haven't been saved to a PDF or permanent storage yet, accidental deletion forces the user to physically rescan the document. This is a higher friction recovery path than restoring a deleted item from a standard list.
**Action:** Always add confirmation dialogs to destructive actions that discard unsaved, user-generated (or captured) data, especially when recreating that data requires physical effort (like scanning a document).
