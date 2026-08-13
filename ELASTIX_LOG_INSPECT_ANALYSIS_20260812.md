# تحليل لوجات Elastix / Asterisk — مطعم رشدي

**الملف المرفوع:** `ELASTIX_LOG_INSPECT_20260812_121404.pdf`  
**حقيقة الملف:** أرشيف ZIP متخفي بامتداد PDF، وتم فكه بنجاح.  
**نوع الفحص:** Read-only فقط — لم يتم حذف أو ضغط أو تعديل أي ملف.

---

## 1) الخلاصة التنفيذية

اللوجات مفيدة جدًا، وخصوصًا `queue_log`. منها نقدر نطلع تقارير أدق بكتير من مجرد CDR:

- مسار كل مكالمة داخل الكيو: دخلت إمتى، رنّت على مين، مين مردش، مين رد بعده، العميل ساب قبل الرد ولا لأ.
- أداء كل Extension/Agent داخل الشيفت.
- تكرار اتصال نفس العميل.
- مؤشرات جودة الشبكة والترانكات من `full`.
- مشاكل في ملفات الترحيب/الانتظار الصوتية.
- حالة أعضاء الكيو الحاليين: مين Online ومين Unavailable.

أهم نتيجة تشغيلية ظهرت:

> في عينة الشيفت الحالية، أغلب المكالمات اترد عليها، لكن فيه Agent/Extension واضح عليه RINGNOANSWER متكرر وهو `1012`، وده بيأخر العميل حوالي 15 ثانية كل محاولة قبل ما يروح لحد تاني.

وأهم نتيجة فنية ظهرت:

> الترانك `SIP_TRUNK_TEdata` فيه flapping واضح بين Reachable / Lagged / Unreachable، ومعاه Retransmission timeouts. ده ممكن يسبب تقطيع/تأخير/مشاكل وصول مكالمات.

---

## 2) حالة المساحة

من الفحص:

```text
/dev/sda1  1.5T  Used 552G  Avail 818G  Use% 41%
```

يعني **المساحة مش أزمة دلوقتي**. مفيش داعي نضغط أو نمسح حاليًا.

---

## 3) أهم الملفات ومعناها

| الملف | المعنى | نستخدمه في إيه؟ | قرارنا الحالي |
|---|---|---|---|
| `queue_log` | سجل تفصيلي لكل أحداث الكيو | Queue Journey / missed ring / abandoned / answered later | مهم جدًا، لا يتم مسحه |
| `full` | لوج Asterisk الرئيسي | مشاكل SIP / trunks / recordings / CDR / AMI | مفيد للتشخيص |
| `cdr-csv/Master.csv` | نسخة CSV من الـ CDR | مقارنة/تأكيد مع DB | مفيد كمرجع احتياطي |
| `master.db` | SQLite داخلي لـ Asterisk DB families | Extensions / Devices / Queue persistent members | قراءة فقط، لا يتعدل |
| `freepbx_dbug` | لوج FreePBX | تحذيرات PHP/Update/DNS | أقل أهمية تشغيليًا |

---

## 4) أرقام Queue الحالية من `queue_log`

العينة الحالية داخل الشيفت أظهرت:

```text
unique_calls_seen      = 90
unique_entered         = 90
unique_answered        = 89
unique_abandoned       = 1
ringnoanswer_attempts  = 16
```

### حسب الكيو

| الكيو | المعنى | دخل | اترد | Abandoned | RINGNOANSWER |
|---|---|---:|---:|---:|---:|
| `1234` | الطلبات | 83 | 82 | 1 | 16 |
| `123` | الشكاوى | 7 | 7 | 0 | 0 |

### أداء الإيجنتات في العينة

| Extension | ردود CONNECT | مكالمات مكتملة | RINGNOANSWER | متوسط انتظار قبل الرد | متوسط مدة الكلام |
|---|---:|---:|---:|---:|---:|
| `1005` | 27 | 26 | 0 | 18.3s | 98.0s |
| `1008` | 26 | 26 | 2 | 11.5s | 81.2s |
| `1014` | 21 | 21 | 0 | 13.3s | 92.9s |
| `1013` | 15 | 15 | 0 | 8.5s | 87.5s |
| `1012` | 0 | 0 | 13 | — | — |
| `1006` | 0 | 0 | 1 | — | — |

**الاستنتاج:**  
`1012` هو أوضح رقم عامل تأخير في الكيو حاليًا. كل RINGNOANSWER تقريبًا بعده تم الرد على المكالمة بواسطة Agent تاني، يعني المكالمة غالبًا ما بتضيعش، بس العميل بيتأخر.

---

## 5) وضع الكيو لحظة الفحص من `asterisk -rx queue show`

### Queue 123 — الشكاوى

```text
123 has 0 calls
strategy: rrmemory
holdtime: 52s
talktime: 55s
C:443
A:133
SL:54.2% within 60s
```

الـ Service Level للشكاوى ضعيف نسبيًا: **54.2% داخل 60 ثانية**.

### Queue 1234 — الطلبات

```text
1234 has 0 calls
strategy: rrmemory
holdtime: 11s
talktime: 127s
C:4933
A:3091
SL:86.9% within 30s
```

الطلبات أحسن: **86.9% داخل 30 ثانية**.

### أعضاء الكيو ومشكلة Unavailable

في Queue 1234 فيه أعضاء كتير Unavailable، ومنهم أرقام كانت بتظهر في RINGNOANSWER مثل `1012`.

ده معناه إن الكيو ممكن يرن على Extension مش جاهز أو مش مسجل صح، فيضيع 15 ثانية من وقت العميل قبل ما يروح لحد تاني.

---

## 6) SIP Peers snapshot

الـ SIP snapshot قال:

```text
37 sip peers
9 online
28 offline
```

Online وقت الفحص:

```text
1000, 1005, 1007, 1008, 1013, 1014
SIP_TRUNK_TEdata, trunk_to_cisco, trunk_to_yeastar
```

أمثلة Extensions Offline/Unknown وقت الفحص:

```text
1001, 1002, 1003, 1004, 1006, 1009, 1010, 1011, 1012, ...
```

**مهم:** لو Extensions Offline موجودة كأعضاء فعّالة في الكيو، ده سبب مباشر لـ RINGNOANSWER وتأخير العملاء.

---

## 7) مشاكل الترانك والشبكة من `full`

في `full_current/tail_200000.txt` ظهر:

```text
SIP_TRUNK_TEdata status changes: 199
Reachable: 100
UNREACHABLE: 52
Lagged: 47
Retransmission timeout reached: 863
```

ده معناه إن `SIP_TRUNK_TEdata` فيه تذبذب واضح. أمثلة ظهرت:

```text
Peer 'SIP_TRUNK_TEdata' is now Lagged
Peer 'SIP_TRUNK_TEdata' is now UNREACHABLE
Peer 'SIP_TRUNK_TEdata' is now Reachable
Retransmission timeout reached ... @10.13.1.248
```

**الاحتمال العملي:**

- مشكلة شبكة بين Elastix والترانك/الراوتر/provider.
- latency أو packet loss.
- NAT/firewall/SIP handling.
- Provider side issue.

ده لا يكسر ERP مباشرة، لكن ممكن يأثر على جودة المكالمات ووصولها.

---

## 8) تحذيرات ملفات الصوت / IVR / Music On Hold

ظهر تكرار عالي لملفات صوت ناقصة:

```text
custom/roshdy_cairo_welcome
no-valid-responce-transfering
/var/lib/asterisk/mohmp3/waiting//wav_roshdy_waiting
```

المعنى:

- ممكن العميل لا يسمع الترحيب المطلوب.
- ممكن يسمع صمت أو يحصل fallback بدل ملف الصوت.
- اللوج يتضخم بسبب التحذيرات المتكررة.

دي نقطة قابلة للإصلاح، لكن لأنها على Elastix لازم Backup قبل أي تعديل.

---

## 9) CDR / ODBC / MySQL

ظهر تحذير متكرر قديم:

```text
res_odbc: Data source name not found
Failed to connect to asteriskcdrdb
```

لكن ظهر أيضًا:

```text
app_cbmysql.c: Successfully connected to MySQL database.
```

وبما إن ERP diagnostics قبل كده أثبتت إن CDR MySQL شغال وعدد السجلات بيتقرأ، فده مش لازم نلمسه دلوقتي.

**القرار:** نسيبه كما هو حاليًا، وما نعدلش ODBC إلا لو في مشكلة واضحة في CDR أو CEL.

---

## 10) FreePBX debug

ظهر:

```text
textdomain() expects exactly 1 parameter
file_get_contents mirror1/mirror2.freepbx.org failed
trim() expects parameter 1 to be string, array given
```

ده غالبًا تحذيرات PHP/FreePBX قديمة ومحاولات Update/DNS فاشلة. مش مؤثر مباشر على ERP أو الكيو، لكنه بيكبر اللوج.

---

## 11) نقدر نعمل إيه عمليًا؟

### A) تحسين Queue Journey داخل ERP — بدون لمس CDR/AMI

نقدر نزود التقرير الحالي بمؤشرات من `queue_log`:

1. مين الإيجنت اللي المكالمة رنت عليه ومردش.
2. مين رد بعدها.
3. مدة التأخير بين عدم الرد والرد اللاحق.
4. عدد RINGNOANSWER لكل Agent في الشيفت.
5. Abandoned الحقيقي مع وقت الانتظار.
6. تكرار اتصال نفس العميل داخل الشيفت.
7. تقسيم واضح: طلبات `1234` وشكاوى `123`.

ده الأفضل لأنه مبني على `queue_log`، ومش محتاج نعدل `report_api.py`.

### B) Health Watchdog للترانكات

نقدر نطوّر الـ Watchdog الحالي يقرأ آخر جزء من `full` Read-only ويطلع:

- عدد مرات `SIP_TRUNK_TEdata` بقى Lagged/Unreachable آخر 15 دقيقة.
- عدد SIP Retransmissions.
- Alert لو الترانك وقع أكتر من Threshold.
- تقرير يومي عن جودة الترانك.

ده هيفيدنا لما حد يقول “المكالمات بتقطع” أو “المكالمات مش داخلة”.

### C) إصلاح أعضاء الكيو Offline / Unavailable

بدون تعديل فوري، نقدر نطلع تقرير:

- أعضاء كل كيو.
- مين Online ومين Offline.
- مين بياخد RINGNOANSWER وهو Offline/Unavailable.
- اقتراح Pause/Remove للأرقام غير المستخدمة.

بعد موافقتك فقط ممكن نعدل من FreePBX أو CLI بطريقة آمنة.

### D) إصلاح ملفات الصوت الناقصة

لو فعلاً العملاء مش سامعين الترحيب/الانتظار، نقدر نعمل:

1. Backup من ملفات الصوت والإعدادات.
2. نتأكد من المسارات المطلوبة.
3. نرفع أو ننشئ ملفات الصوت الناقصة بنفس الأسماء المطلوبة.
4. Reload خفيف للـ MOH/Config لو لزم.

ده لازم يتعمل بحذر لأنه على Elastix مباشرة.

### E) Phone normalization

ظهر إن أرقام العملاء جاية بصيغ مختلفة:

```text
+2010...
2010...
010...
```

نقدر نوحّد عرض الأرقام في تقارير ERP عشان نفس العميل ما يبانش كذا عميل.

---

## 12) الأولويات المقترحة

1. **أولوية عالية:** تقرير Queue Journey أدق من `queue_log` + RINGNOANSWER by agent.
2. **أولوية عالية:** Watchdog للترانك `SIP_TRUNK_TEdata` بسبب التذبذب.
3. **أولوية متوسطة:** تقرير أعضاء الكيو Offline/Unavailable.
4. **أولوية متوسطة:** إصلاح ملفات الصوت الناقصة لو العملاء بيسمعوا صمت/مشاكل IVR.
5. **أولوية منخفضة الآن:** FreePBX debug و ODBC warnings طالما CDR شغال.

---

## 13) حاجات ممنوع نعملها عشوائيًا

- لا نمسح `queue_log`.
- لا نمسح `master.db`.
- لا نعدل `report_api.py` لمجرد تحسين Queue Journey.
- لا نغير إعدادات CDR/AMI/ODBC إلا بقرار واضح وBackup.
- لا نعمل reload/restart لـ Asterisk في وقت شغل بدون سبب واضح.

---

## 14) القرار الفني الآمن

أفضل خطوة جاية:

> نعمل سكريبت ERP Read-only يقرأ Cache الـ Queue Journey الحالي المستخرج من `queue_log`، ويطلع Dashboard/Email section فيه: RINGNOANSWER by agent + answered later + abandoned + repeated callers + queue SLA، بدون أي تعديل على CDR/AMI/report_api.

وبعدها لو حبيت نروح ناحية Elastix نفسه، نبدأ بملفات الصوت أو عضوية الكيو، لكن بعد Backup وموافقة صريحة.
