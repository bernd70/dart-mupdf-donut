# dart_mupdf_donut

A comprehensive **pure Dart** PDF library **+** OCR-free Document Understanding Transformer ([Donut](https://arxiv.org/abs/2111.15664)).  
No native dependencies — works on **all platforms** (Android, iOS, Web, macOS, Windows, Linux).

[![pub package](https://img.shields.io/pub/v/dart_mupdf_donut.svg)](https://pub.dev/packages/dart_mupdf_donut)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub](https://img.shields.io/github/stars/proethiopia/dart-mupdf-donut?style=social)](https://github.com/proethiopia/dart-mupdf-donut)

---

## Why This Package?

Most Dart/Flutter PDF libraries either need native C bindings (FFI) or can only
display PDFs.  **dart_mupdf_donut** is different:

- **100 % pure Dart** — no C code, no platform channels, no FFI.  Runs on
  every platform Flutter supports, including Web.
- **Full PDF engine** — not just a viewer.  Parse, edit, create, merge, and
  save PDFs entirely in Dart, inspired by the battle-tested
  [PyMuPDF](https://github.com/pymupdf/PyMuPDF) API.
- **Page rendering** — `Page.getPixmap()` renders a page to an RGB/RGBA pixel
  buffer that you can save as PNG, JPEG, or feed to any image widget.
- **Reactive state** — built-in `DocumentController` powered by
  [RxDart](https://pub.dev/packages/rxdart) gives you observable streams for
  page navigation, zoom, loading state, and errors.
- **OCR-free AI** — the Donut module runs a Swin + BART transformer *entirely
  in Dart* to extract structured JSON from receipt/invoice images — no cloud
  API, no OCR, no native ML runtime.

---

## What's Inside

| Module | Description |
|--------|-------------|
| **dart_mupdf** | Pure Dart PDF engine inspired by [PyMuPDF](https://github.com/pymupdf/PyMuPDF) — parse, extract text/images, render pages, annotate, merge, create PDFs |
| **Reactive Layer** | `DocumentController` + `DocumentState` — RxDart-powered state management for page navigation, zoom, rendering, and text extraction |
| **Batch Utilities** | `BatchRenderer` — thumbnail generation, full-text search across pages, bulk PNG export |
| **donut** | Pure Dart [Donut](https://github.com/clovaai/donut) implementation — Swin Transformer encoder + mBART decoder for structured document extraction from images (receipts, invoices, forms) |

---

## Table of Contents

- [Why This Package?](#why-this-package)
- [What's Inside](#whats-inside)
- [Installation](#installation)
- [Quick Start — PDF](#quick-start--pdf)
- [Rendering Pages (getPixmap)](#rendering-pages-getpixmap)
- [Reactive State Management (RxDart)](#reactive-state-management-rxdart)
- [Batch Operations](#batch-operations)
- [PDF Features Comparison](#pdf-features-comparison)
- [PDF Advanced Usage](#pdf-advanced-usage)
- [Quick Start — Donut](#quick-start--donut)
- [Donut Architecture](#donut-architecture)
- [Donut Supported Tasks](#donut-supported-tasks)
- [Donut Configuration](#donut-configuration)
- [Donut Image Preprocessing](#donut-image-preprocessing)
- [Donut JSON ↔ Token Conversion](#donut-json--token-conversion)
- [Tensor Operations](#tensor-operations)
- [Neural Network Layers](#neural-network-layers)
- [Exporting Weights from Python](#exporting-weights-from-python)
- [API Reference](#api-reference)
- [Platform Support](#platform-support)
- [Migration from 1.0.0 → 0.1.2](#migration-from-100--012)
- [License](#license)
- [References](#references)

---

## Installation

```yaml
dependencies:
  dart_mupdf_donut: ^0.1.2
```

```bash
dart pub get
```

---

## Quick Start — PDF

```dart
import 'dart:io';
import 'package:dart_mupdf_donut/dart_mupdf.dart';

void main() {
  // ── Open a PDF ──────────────────────────────────────────────
  final bytes = File('invoice.pdf').readAsBytesSync();
  final doc   = DartMuPDF.openBytes(bytes);
  print('Pages : ${doc.pageCount}');
  print('Title : ${doc.metadata.title}');

  // ── Extract text ────────────────────────────────────────────
  final page = doc.getPage(0);
  print(page.getText());

  // ── Render to image ─────────────────────────────────────────
  final pix = page.getPixmap();                   // ← NEW in 0.1.2
  File('page0.png').writeAsBytesSync(pix.toPng());

  // ── Search ──────────────────────────────────────────────────
  for (final rect in page.searchFor('Total')) {
    print('Found "Total" at $rect');
  }

  // ── Extract images ──────────────────────────────────────────
  for (final info in page.getImages()) {
    final img = doc.extractImage(info.xref);
    if (img != null) print('Image ${info.xref}: ${img.width}×${img.height}');
  }

  // ── Table of contents ───────────────────────────────────────
  for (final entry in doc.getToc()) {
    print('${"  " * (entry.level - 1)}${entry.title} → p.${entry.pageNumber}');
  }

  doc.close();
}
```

---

## Rendering Pages (getPixmap)

> **This was the #1 requested feature.**  In v1.0.0 the `Pixmap` class existed
> but there was no way to get one from a `Page`.  As of **0.1.2** the method is
> fully available.

```dart
final page = doc.getPage(0);

// Default render (72 DPI, RGB, no alpha)
final pix = page.getPixmap();
File('page.png').writeAsBytesSync(pix.toPng());

// 2× zoom (144 DPI equivalent)
final hires = page.getPixmap(matrix: Matrix.scale(2, 2));

// Grayscale
final gray = page.getPixmap(colorspace: Colorspace.csGray);

// With transparency
final rgba = page.getPixmap(alpha: true);

// Convenience helpers
File('page.png').writeAsBytesSync(page.renderToPng());
File('page.jpg').writeAsBytesSync(page.renderToJpeg(quality: 85));
```

### Pixmap Operations

```dart
final pix = page.getPixmap();

// Crop a region
final cropped = pix.crop(IRect(50, 50, 400, 300));

// Scale (bilinear interpolation)
final thumb = pix.scale(150, 200);

// Convert colorspace
final cmyk = pix.toColorspace(Colorspace.csCmyk);

// Save directly to file
pix.save('output.png');     // format inferred from extension
pix.save('output.jpg');
pix.save('output.bmp');

// Manipulate pixels
pix.invertIRect();
pix.gammaWith(1.5);
pix.tintWith(0, 200);
```

---

## Reactive State Management (RxDart)

`DocumentController` wraps the `Document` in an observable, immutable state
stream.  Perfect for Flutter `StreamBuilder` / BLoC / Riverpod integration.

```dart
import 'package:dart_mupdf_donut/dart_mupdf.dart';

final ctrl = DocumentController();

// Subscribe to state changes
ctrl.state$.listen((s) {
  print('Page ${s.currentPage + 1} / ${s.pageCount}  '
        'zoom: ${(s.zoom * 100).toInt()}%');
});

// Open
ctrl.openBytes(pdfBytes);

// Navigate
ctrl.nextPage();
ctrl.previousPage();
ctrl.goToPage(5);
ctrl.firstPage();
ctrl.lastPage();

// Zoom
ctrl.setZoom(2.0);    // 200 %
ctrl.zoomIn();         // +25 %
ctrl.zoomOut(0.5);     // −50 %

// Render current page (internally LRU-cached)
final pix = ctrl.renderPage();
final png = ctrl.renderToPng();

// Extract text
final text     = ctrl.getText();           // current page
final fullText = ctrl.getFullText();       // all pages

// Fine-grained streams (distinct, no duplicates)
ctrl.currentPage$.listen((p) => print('Page changed: $p'));
ctrl.zoom$.listen((z)         => print('Zoom changed: $z'));
ctrl.isLoading$.listen((l)    => print('Loading: $l'));
ctrl.errors$.listen((e)       => print('Error: $e'));

// Cleanup
ctrl.dispose();
```

### Flutter Example (StreamBuilder)

```dart
StreamBuilder<DocumentState>(
  stream: ctrl.state$,
  builder: (context, snap) {
    final s = snap.data;
    if (s == null || !s.isOpen) return CircularProgressIndicator();
    final png = ctrl.renderToPng();
    return Column(children: [
      Text('Page ${s.currentPage + 1} / ${s.pageCount}'),
      Image.memory(png),
      Row(children: [
        IconButton(icon: Icon(Icons.arrow_back), onPressed: ctrl.previousPage),
        IconButton(icon: Icon(Icons.arrow_forward), onPressed: ctrl.nextPage),
        IconButton(icon: Icon(Icons.zoom_in), onPressed: ctrl.zoomIn),
        IconButton(icon: Icon(Icons.zoom_out), onPressed: ctrl.zoomOut),
      ]),
    ]);
  },
);
```

---

## Batch Operations

For processing many pages at once (thumbnails, search, export):

```dart
import 'package:dart_mupdf_donut/dart_mupdf.dart';

final doc = DartMuPDF.openFile('report.pdf');
final batch = BatchRenderer(doc);

// Generate thumbnails (max 150 px)
final thumbs = batch.renderThumbnails(maxDimension: 150);
thumbs.forEach((i, pix) => pix.save('thumb_$i.png'));

// Full-text search across all pages
final hits = batch.searchAll('revenue');
hits.forEach((page, rects) {
  print('Page $page: ${rects.length} matches');
});

// Extract all text
final texts = batch.extractAllText();
File('fulltext.txt').writeAsStringSync(texts.join('\n\n'));

// Export all pages to PNG
final pngs = batch.exportAllToPng(matrix: Matrix.scale(2, 2));
for (var i = 0; i < pngs.length; i++) {
  File('page_$i.png').writeAsBytesSync(pngs[i]);
}

doc.close();
```

---

## PDF Features Comparison

| Feature | PyMuPDF (Python) | dart_mupdf_donut (Dart) |
|---------|------------------|-------------------------|
| Open PDF from file/bytes | ✅ `fitz.open()` | ✅ `DartMuPDF.openFile()` / `openBytes()` |
| Page count & metadata | ✅ `doc.page_count` | ✅ `doc.pageCount` / `doc.metadata` |
| **Render page → Pixmap** | ✅ `page.get_pixmap()` | ✅ **`page.getPixmap()`** *(new in 0.1.2)* |
| Extract plain text | ✅ `page.get_text()` | ✅ `page.getText()` |
| Extract text blocks | ✅ `page.get_text("blocks")` | ✅ `page.getTextBlocks()` |
| Extract text words | ✅ `page.get_text("words")` | ✅ `page.getTextWords()` |
| Extract text as dict | ✅ `page.get_text("dict")` | ✅ `page.getTextDict()` |
| Search text | ✅ `page.search_for()` | ✅ `page.searchFor()` |
| Get images list | ✅ `page.get_images()` | ✅ `page.getImages()` |
| Extract image bytes | ✅ `doc.extract_image()` | ✅ `doc.extractImage()` |
| Get links | ✅ `page.get_links()` | ✅ `page.getLinks()` |
| Table of contents | ✅ `doc.get_toc()` | ✅ `doc.getToc()` |
| Annotations | ✅ `page.annots()` | ✅ `page.getAnnotations()` |
| Insert text | ✅ `page.insert_text()` | ✅ `page.insertText()` |
| Insert image | ✅ `page.insert_image()` | ✅ `page.insertImage()` |
| Merge PDFs | ✅ `doc.insert_pdf()` | ✅ `doc.insertPdf()` |
| Delete / rotate / copy pages | ✅ | ✅ |
| Create new PDF | ✅ `fitz.open()` | ✅ `DartMuPDF.createPdf()` |
| Save to bytes / file | ✅ `doc.tobytes()` | ✅ `doc.toBytes()` / `doc.save()` |
| Pixmap crop / scale | ✅ | ✅ **`pix.crop()` / `pix.scale()`** *(new)* |
| Pixmap save to file | ✅ | ✅ **`pix.save()`** *(fixed)* |
| Reactive state mgmt | ❌ | ✅ **`DocumentController`** *(new)* |
| Batch rendering | ❌ | ✅ **`BatchRenderer`** *(new)* |
| Encryption & auth | ✅ | ✅ `doc.isEncrypted` / `doc.authenticate()` |
| Embedded files | ✅ `doc.embfile_*` | ✅ `doc.embeddedFiles` |
| Form fields | ✅ `page.widgets()` | ✅ `page.getWidgets()` |
| Page labels | ✅ | ✅ `doc.getPageLabels()` |

---

## PDF Advanced Usage

### Text Extraction Modes

```dart
final text   = page.getText();           // plain text
final blocks = page.getTextBlocks();     // blocks with position
final words  = page.getTextWords();      // individual words
final dict   = page.getTextDict();       // full structure
final html   = page.getText(format: TextFormat.html);
```

### Page Manipulation

```dart
doc.deletePage(2);
doc.getPage(0).setRotation(90);
doc.movePage(from: 5, to: 0);
doc.select([0, 2, 4]);
doc.copyPage(0, to: doc.pageCount);
```

### Annotations

```dart
for (final a in page.getAnnotations()) {
  print('${a.type}: ${a.content}');
}
page.addHighlightAnnot(quads);
page.addTextAnnot(Point(100, 100), 'Note');
```

### Drawing with Shape

```dart
final shape = Shape(pageWidth: 595, pageHeight: 842);
shape.drawRect(Rect(50, 50, 300, 200));
shape.finish(color: [1, 0, 0], fill: [0.9, 0.9, 1.0], width: 1);
shape.drawCircle(Point(200, 400), 50);
shape.finish(color: [0, 0, 1], width: 1.5);
final stream = shape.commit();
```

---

## Quick Start — Donut

```dart
import 'package:dart_mupdf_donut/donut.dart';
import 'dart:io';

// 1. Configure & build model
final config = DonutConfig.base();
final model  = DonutModel(config);

// 2. Load pretrained weights (from HuggingFace export)
await model.loadWeights('path/to/donut-model/');
model.loadTokenizerFromFile('path/to/tokenizer.json');

// 3. Run inference on a receipt image
final bytes  = File('receipt.jpg').readAsBytesSync();
final result = model.inferenceFromBytes(
  imageBytes: bytes,
  prompt: '<s_cord-v2>',
);

// 4. Structured JSON output
print(result.json);
// {
//   "menu": [
//     {"nm": "Cappuccino", "price": "4.50"},
//     {"nm": "Croissant",  "price": "3.00"}
//   ],
//   "total": {"total_price": "7.50"}
// }
```

### Combine PDF + Donut

```dart
import 'package:dart_mupdf_donut/dart_mupdf.dart';
import 'package:dart_mupdf_donut/donut.dart';

final doc  = DartMuPDF.openBytes(pdfBytes);
final page = doc.getPage(0);

// Render the page to an image, then feed it to Donut
final png = page.getPixmap(matrix: Matrix.scale(2, 2)).toPng();

final model = DonutModel(DonutConfig.base());
await model.loadWeights('model/');
model.loadTokenizerFromFile('tokenizer.json');

final result = model.inferenceFromBytes(
  imageBytes: png,
  prompt: '<s_cord-v2>',
);
print(result.json);
doc.close();
```

---

## Donut Architecture

```
Document Image
      │
      ▼
┌─────────────────────────┐
│     Swin Encoder         │  Hierarchical vision transformer
│  Patch Embed → Stages    │  Window attention + patch merging
│  [2, 2, 14, 2] layers   │  Output: (1, N, 1024) features
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│     BART Decoder         │  Auto-regressive text decoder
│  Cross-attention to      │  4 layers × 16 heads
│  encoder features        │  Generates structured tokens
└───────────┬─────────────┘
            │
            ▼
    Structured JSON Output
```

**Key insight**: Donut skips OCR entirely — it learns to read documents end-to-end from pixels to structured data.

---

## Donut Supported Tasks

| Task | Prompt | Output |
|------|--------|--------|
| **Receipt Parsing** (CORD-v2) | `<s_cord-v2>` | Menu items, prices, totals |
| **Document Classification** (RVL-CDIP) | `<s_rvlcdip>` | `"letter"`, `"invoice"`, etc. |
| **Visual QA** (DocVQA) | `<s_docvqa><s_question>…</s_question><s_answer>` | Free-text answer |
| **Text Reading** (SynthDoG) | `<s_synthdog>` | OCR-free text |

---

## Donut Configuration

```dart
// Default (matches HuggingFace donut-base)
final config = DonutConfig.base();

// Custom
final config = DonutConfig(
  inputSize: [1280, 960],
  windowSize: 10,
  encoderLayer: [2, 2, 14, 2],
  decoderLayer: 4,
  maxLength: 1536,
  encoderEmbedDim: 128,
  encoderNumHeads: [4, 8, 16, 32],
  decoderEmbedDim: 1024,
  decoderFfnDim: 4096,
  decoderNumHeads: 16,
  vocabSize: 57522,
);

// Small (for testing / dev)
final config = DonutConfig.small();

// From HuggingFace config.json
final config = DonutConfig.fromJson(jsonDecode(str));
```

---

## Donut Image Preprocessing

```dart
// From file bytes (PNG, JPEG, etc.)
final tensor = DonutImageUtils.preprocessBytes(imageBytes, config);
// → Tensor shape [1, 3, H, W] with ImageNet normalization

// Pipeline description
print(DonutImageUtils.describePipeline(config));
// 1. Decode → RGB
// 2. Resize to fit [H, W] (aspect ratio preserved)
// 3. Pad with white
// 4. Normalize: (px/255 − μ) / σ   (ImageNet stats)
// 5. → Tensor [1, 3, H, W]

// Debug: tensor back to image
final debugImg = DonutImageUtils.tensorToImage(tensor);
```

---

## Donut JSON ↔ Token Conversion

Donut uses XML-like tokens for structured output:

```dart
// JSON → Donut tokens
final tokens = DonutModel.json2token({
  'menu': [
    {'nm': 'Latte',  'price': '5.0'},
    {'nm': 'Muffin', 'price': '3.5'},
  ],
  'total': {'total_price': '8.5'},
});
// → '<s_menu><s_nm>Latte</s_nm><s_price>5.0</s_price><sep/>
//    <s_nm>Muffin</s_nm><s_price>3.5</s_price></s_menu>
//    <s_total><s_total_price>8.5</s_total_price></s_total>'

// Donut tokens → JSON
final json = DonutModel.token2json(tokens);
// → {'menu': [...], 'total': {'total_price': '8.5'}}
```

---

## Tensor Operations

```dart
import 'package:dart_mupdf_donut/donut.dart';

final a = Tensor.zeros([2, 3]);
final b = Tensor.ones([2, 3]);
final c = a + b;                 // element-wise add
final d = c * Tensor.full([2, 3], 2.0);

// Matrix multiply
final y = Tensor.ones([2, 4]).matmul(Tensor.ones([4, 3]));

// Reshape, permute, transpose
final r = y.reshape([1, 2, 3]);
final p = r.permute([0, 2, 1]);

// Reductions
final s = y.sum(1);
final m = y.mean(0);

// Activations
final g = y.gelu();
final sm = y.softmax(1);
```

---

## Neural Network Layers

```dart
final linear = Linear(512, 256);
final output = linear.forward(input);

final norm = LayerNorm(256);
final normalized = norm.forward(output);

final embed = Embedding(50000, 1024);
final embedded = embed.forward([1, 42, 100]);

final attn = MultiHeadAttention(embedDim: 1024, numHeads: 16);
final attended = attn.forward(query, key, value);

final conv = Conv2d(3, 64, 4, stride: 4);
final features = conv.forward(imageTensor);
```

---

## Exporting Weights from Python

### Safetensors (recommended)

```bash
pip install huggingface_hub
python -c "
from huggingface_hub import snapshot_download
snapshot_download('naver-clova-ix/donut-base-finetuned-cord-v2',
                  local_dir='./donut-cord-v2/')
"
```

### JSON (portable)

```python
import torch, json, base64
from transformers import VisionEncoderDecoderModel

model = VisionEncoderDecoderModel.from_pretrained(
    "naver-clova-ix/donut-base-finetuned-cord-v2"
)

weights = {}
for name, param in model.named_parameters():
    t = param.detach().cpu().float().numpy()
    weights[name] = {
        "shape": list(t.shape),
        "dtype": "float32",
        "data": base64.b64encode(t.tobytes()).decode("ascii"),
    }

with open("weights.json", "w") as f:
    json.dump(weights, f)
```

---

## API Reference

### PDF Core

| Class | Description |
|-------|-------------|
| `DartMuPDF` | Entry point — `openFile()`, `openBytes()`, `createPdf()` |
| `Document` | PDF document — pages, metadata, TOC, merge, save |
| `Page` | Single page — text, images, links, annotations, **`getPixmap()`** |
| `Pixmap` | Pixel buffer — crop, scale, convert, export PNG/JPEG/BMP |
| `Shape` | Drawing API — lines, rects, circles, text |
| `TextPage` | Parsed text layer — blocks, words, search |

### Reactive & Utilities *(new in 0.1.2)*

| Class | Description |
|-------|-------------|
| `DocumentController` | RxDart-powered state management — navigation, zoom, render cache |
| `DocumentState` | Immutable state snapshot — currentPage, pageCount, zoom, metadata, toc |
| `BatchRenderer` | Bulk operations — thumbnails, full-text, search-all, export-all |

### Donut Core

| Class | Description |
|-------|-------------|
| `DonutModel` | Main model — encoder + decoder + inference |
| `DonutConfig` | All hyperparameters (input size, layers, dims) |
| `DonutResult` | Output — `.tokens`, `.text`, `.json` |
| `DonutTokenizer` | SentencePiece BPE tokenizer |
| `DonutImageUtils` | Resize, normalize, pad images |
| `DonutWeightLoader` | Load safetensors / JSON weights |

### Donut Encoder / Decoder

| Class | Description |
|-------|-------------|
| `SwinEncoder` | Swin Transformer visual encoder |
| `BartDecoder` | mBART auto-regressive decoder |
| `SwinTransformerBlock` | Window attention block |
| `BartDecoderLayer` | Self-attn → cross-attn → FFN |
| `WindowAttention` | Shifted window attention |
| `PatchEmbed` | Conv2d patch embedding |
| `PatchMerging` | 2× spatial downsample |

### Tensor & NN

| Class | Description |
|-------|-------------|
| `Tensor` | N-dim array — matmul, softmax, GELU, broadcasting |
| `Linear` | y = xW^T + b |
| `LayerNorm` | Layer normalization |
| `Embedding` | Token / position lookup |
| `Conv2d` | 2D convolution |
| `MultiHeadAttention` | Scaled dot-product attention |
| `FeedForward` | 2-layer MLP + GELU |

### Geometry

| Class | Description |
|-------|-------------|
| `Point` | 2D point |
| `Rect` | Bounding rectangle |
| `IRect` | Integer rectangle |
| `Matrix` | 3×3 transformation matrix |
| `Quad` | Quadrilateral (4 points) |

### Compatible Pretrained Models

| Model | Task | HuggingFace ID |
|-------|------|----------------|
| Donut Base | General | `naver-clova-ix/donut-base` |
| CORD v2 | Receipt parsing | `naver-clova-ix/donut-base-finetuned-cord-v2` |
| RVL-CDIP | Doc classification | `naver-clova-ix/donut-base-finetuned-rvlcdip` |
| DocVQA | Visual QA | `naver-clova-ix/donut-base-finetuned-docvqa` |

---

## Platform Support

| Platform | Status |
|----------|--------|
| Android | ✅ |
| iOS | ✅ |
| Web | ✅ |
| macOS | ✅ |
| Windows | ✅ |
| Linux | ✅ |

---

## Migration from 1.0.0 → 0.1.2

Version **0.1.2** is fully backward-compatible.  No breaking changes — only
additions:

| What changed | Details |
|--------------|---------|
| `Page.getPixmap()` added | Renders a page to `Pixmap`.  Was not available in 1.0.0. |
| `Page.renderToPng()` / `renderToJpeg()` added | Convenience wrappers. |
| `Pixmap.crop()` / `scale()` added | Sub-region extraction and bilinear resize. |
| `Pixmap.save()` fixed | Was a no-op stub; now writes to disk. |
| `DocumentController` added | RxDart-based reactive state management. |
| `BatchRenderer` added | Bulk page operations. |
| `rxdart` dependency added | Required by `DocumentController`. |

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## References

- **PyMuPDF**: [github.com/pymupdf/PyMuPDF](https://github.com/pymupdf/PyMuPDF)
- **flutter_mupdf**: [pub.dev/packages/flutter_mupdf](https://pub.dev/packages/flutter_mupdf) — native MuPDF wrapper (inspiration for `getPixmap` API)
- **Donut**: Kim et al., *"OCR-free Document Understanding Transformer"*, ECCV 2022 — [arXiv:2111.15664](https://arxiv.org/abs/2111.15664) | [Code](https://github.com/clovaai/donut)
- **Swin Transformer**: Liu et al., *"Hierarchical Vision Transformer using Shifted Windows"*, ICCV 2021
- **BART**: Lewis et al., *"Denoising Sequence-to-Sequence Pre-training"*, ACL 2020
