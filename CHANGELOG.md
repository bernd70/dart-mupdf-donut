## 0.1.2

### Page Rendering, Reactive State & Pixmap Improvements

- **`Page.getPixmap()`** — Render any PDF page to a `Pixmap` pixel buffer.
  Supports `matrix` (zoom/DPI), `colorspace`, `clip` region, and `alpha` channel.
- **`Page.renderToPng()` / `renderToJpeg()`** — Convenience methods for
  one-step page-to-image export.
- **`Pixmap.save()` fixed** — Was a no-op stub; now writes PNG/JPEG/BMP to disk.
- **`Pixmap.crop(IRect)`** — Extract a sub-region from any pixmap.
- **`Pixmap.scale(width, height)`** — Resize with bilinear interpolation.
- **`DocumentController`** — RxDart-powered reactive state management:
  page navigation, zoom, render caching, observable streams.
- **`BatchRenderer`** — Bulk operations: thumbnails, full-text search across
  pages, export-all-to-PNG.
- **`rxdart ^0.28.0`** dependency added.
- **README** rewritten with detailed documentation for all new features.
- **72 tests passing** (47 original + 25 new).

## 1.1.0

### Donut Model — Real Pretrained Weight Support

- **Real receipt extraction**: Example loads pretrained `donut-base-finetuned-cord-v2` weights and runs actual inference on receipt images
- **Weight converter**: Added `tools/convert_weights.py` to convert HuggingFace PyTorch models to safetensors format compatible with Dart loader
- **Tokenizer fix**: `DonutTokenizer.fromJson` now supports both BPE (`vocab` as Map) and Unigram (`vocab` as List) HuggingFace formats
- **Donut normalization**: Fixed image preprocessing to use correct mean/std = [0.5, 0.5, 0.5] (was incorrectly using ImageNet values)
- **mBART layernorm**: Added `layernorm_embedding` layer to BartDecoder (required by mBART architecture)
- **Weight loader**: Fixed encoder layer regex to match converted safetensors naming, added `layernorm_embedding` weight loading
- **Config**: Updated default `vocabSize` to 57525, `alignLongAxis` to true
- **Example**: Rewrote `example.dart` to demonstrate real pretrained model inference on receipt images

## 1.0.0

Initial release of **dart_mupdf_donut** — a pure Dart PDF library with
OCR-free document understanding.

### PDF Module (dart_mupdf)

- PDF parsing engine (cross-reference table, indirect objects, streams)
- Document class — open from file/bytes, save, metadata, TOC, page manipulation
- Page class — text extraction, images, links, annotations, search
- Text extraction: plain text, blocks, words, dict, HTML, XML, XHTML
- Image extraction from PDF pages
- Annotation reading and creation (highlight, underline, strikeout, text, freetext, ink, stamp)
- Table of contents extraction and modification
- PDF manipulation: merge, split, rotate, delete, copy, move pages
- Metadata reading and writing
- Link extraction and creation
- Form field (widget) reading
- Embedded file support
- Page labels
- Encryption detection and password authentication
- PDF creation from scratch
- Cross-reference (xref) object access
- Geometry types: Rect, Point, Matrix, Quad, IRect
- Colorspace support
- Deflate/inflate stream compression
- Drawing API (Shape) for lines, rectangles, circles, curves
- Pixmap — pixel buffer with colorspace conversion and PNG export
- Pure Dart — no native dependencies, works on all platforms

### Donut Module (OCR-free Document Understanding)

- Pure Dart implementation of Donut (ECCV 2022)
- **Swin Transformer encoder** — hierarchical vision transformer with shifted
  windows, patch embedding, patch merging
- **mBART decoder** — auto-regressive text decoder with cross-attention to
  encoder features, KV caching for fast generation
- **Tensor** class — N-dimensional array with Float32List, matmul, softmax,
  GELU, broadcasting, sum/mean/max reductions, reshape/permute/transpose
- Neural network layers: Linear, LayerNorm, Embedding, Conv2d,
  MultiHeadAttention, FeedForward
- **DonutTokenizer** — SentencePiece BPE tokenizer compatible with
  HuggingFace format, special token support
- **DonutImageUtils** — image preprocessing (resize, pad, ImageNet
  normalization), tensor ↔ image roundtrip
- **DonutWeightLoader** — load weights from safetensors or JSON format
- **DonutConfig** — full configuration (base, small, custom, fromJson)
- JSON ↔ Donut token conversion (`json2token` / `token2json`)
- Support for CORD-v2 (receipts), RVL-CDIP (classification), DocVQA,
  SynthDoG tasks
- Random weight initialization for testing (`model.randomInit()`)
- Compatible with HuggingFace pretrained Donut models
