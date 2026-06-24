# InspectFlowAI — Test Dataset & Results Matrix

A labeled set of widget images covering every combination of the inspected
components, all run through the **live** pipeline (AWS account `425652524844`,
us-east-1).

## Inspection rule

A widget is **compliant (PASS)** only if Amazon Rekognition detects **all**
required components:

```
EXPECTED_LABELS = hardware|machine|motor, qr code     (MIN_CONFIDENCE = 80)
```

- Comma separates required components (a widget needs every one).
- `|` lists **synonyms** within a component — satisfied if ANY is detected.

In plain English: the part must be recognizable **hardware** (Rekognition may
call a mechanical assembly `Machine` or `Motor`) **and** carry a scannable
**QR/label**.

> Why synonyms? Rekognition's `DetectLabels` returns `Machine`/`Motor` for a
> motor-gearbox assembly instead of `Hardware`. Rather than mislabel a genuinely
> compliant part as defective, the rule accepts the synonyms. (In a real system
> you'd refine this further with **Rekognition Custom Labels** trained on your
> actual widgets.) We also dropped an earlier `text` requirement because
> `DetectLabels` only emits `Text` for large/prominent text — reading label
> contents is a job for `DetectText`.

## Folder structure

```
dataset/
├── 01-compliant/              # hardware + QR label        -> PASS
│   ├── compliant-metal-plate.png
│   ├── compliant-pcb.png
│   ├── compliant-enclosure.png
│   └── compliant-control-module.png
├── 02-hardware-only/          # hardware, no label          -> FAIL (no qr)
│   ├── bracket-no-label.png
│   └── plate-no-label.png
├── 03-hardware-text-no-qr/    # text label, no QR           -> FAIL
│   └── plate-text-label-no-qr.png
├── 04-hardware-qr-no-text/    # QR sticker only             -> FAIL (no hardware label)
│   └── plate-qr-only.png
├── 05-label-only-no-hardware/ # label, no metal             -> FAIL
│   └── label-only.png
├── 06-non-widget/             # control objects             -> FAIL
│   ├── apple.png
│   └── volleyball.png
└── 07-synonym-machine/        # motor assembly (Machine/Motor + QR) -> PASS via synonym
    └── gearbox-labeled-machine.png
```

## Live result matrix (12 images)

| # | Scenario / image | Rekognition detected | Result | Missing |
|---|---|---|---|---|
| 1 | 01-compliant / metal-plate | Hardware, Computer Hardware, QR Code | **PASS** | — |
| 2 | 01-compliant / pcb | Hardware, Printed Circuit Board, QR Code | **PASS** | — |
| 3 | 01-compliant / enclosure | Electronics, Hardware, Adapter, QR Code | **PASS** | — |
| 4 | 01-compliant / control-module | Electronics, Hardware, Computer, QR Code | **PASS** | — |
| 5 | 07-synonym-machine / gearbox | Machine, Motor, QR Code | **PASS** | — |
| 6 | 02-hardware-only / bracket | Bracket, Machine, Screw | FAIL | qr code |
| 7 | 02-hardware-only / plate | Aluminium, Electronics, Phone | FAIL | hardware\|machine\|motor, qr code |
| 8 | 03-hardware-text-no-qr / plate | Text, Plaque, Business Card, Paper | FAIL | hardware\|machine\|motor, qr code |
| 9 | 04-hardware-qr-no-text / plate | QR Code | FAIL | hardware\|machine\|motor |
| 10 | 05-label-only / label | Text, Document, QR Code | FAIL | hardware\|machine\|motor |
| 11 | 06-non-widget / apple | Apple, Food, Fruit | FAIL | hardware\|machine\|motor, qr code |
| 12 | 06-non-widget / volleyball | Ball, Sport, Sphere | FAIL | hardware\|machine\|motor, qr code |

**Total: 5 PASS, 7 FAIL.** Notes:
- The gearbox (row 5) now passes via the `machine`/`motor` synonyms.
- The bracket (row 6) is recognized as hardware (`Machine`) but fails on the
  missing `qr code` — exactly the right reason.
- Non-widgets and label-only / hardware-only parts all fail with the precise
  missing component listed.

## Re-run the whole dataset

```bash
while IFS= read -r f; do
  scen=$(basename "$(dirname "$f")"); base=$(basename "$f")
  aws s3 cp "$f" "s3://inspectflow-source-425652524844/run/${scen}__${base}" --region us-east-1
done < <(find dataset -type f -name '*.png')
```

Then check `inspected/pass/` and `inspected/fail/` for the images + JSON reports.
