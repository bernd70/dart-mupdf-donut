# Answer: Where Is `getPixmap()` in dart_mupdf_donut?

## The Problem (v1.0.0)

In **v1.0.0** of `dart_mupdf_donut`, the `Page` class did **not** have a
`getPixmap()` method.  The `Pixmap` class existed (with color conversion,
PNG export, etc.) but there was no way to obtain one from a page — you could
not render a PDF page to pixels.

Additionally:

- `Pixmap.save()` was a **no-op stub** — it did nothing.
- `Pixmap` had no `crop()` or `scale()` methods.

This was a significant gap compared to PyMuPDF (`page.get_pixmap()`) and
flutter_mupdf (`getPagePixmap()`).

---

## The Fix (v0.1.2)

### `Page.getPixmap()` — now available

```dart
import 'package:dart_mupdf_donut/dart_mupdf.dart';

final doc  = DartMuPDF.openBytes(pdfBytes);
final page = doc.getPage(0);

// Basic render (72 DPI, RGB, white background)
final pix = page.getPixmap();
File('page.png').writeAsBytesSync(pix.toPng());
```

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `matrix` | `Matrix?` | `Matrix.identity` | Transformation matrix (use `Matrix.scale(2, 2)` for 144 DPI) |
| `colorspace` | `Colorspace?` | `Colorspace.csRgb` | Color model — `csRgb`, `csGray`, `csCmyk` |
| `clip` | `IRect?` | full page | Render only this rectangular region |
| `alpha` | `bool` | `false` | `true` → RGBA with transparent background; `false` → RGB with white background |

#### Examples

```dart
// High resolution (2× zoom = 144 DPI)
final hires = page.getPixmap(matrix: Matrix.scale(2, 2));

// Grayscale
final gray = page.getPixmap(colorspace: Colorspace.csGray);

// With transparency (RGBA)
final rgba = page.getPixmap(alpha: true);

// Crop to a region
final region = page.getPixmap(clip: IRect(0, 0, 300, 200));

// All combined
final custom = page.getPixmap(
  matrix: Matrix.scale(3, 3),
  colorspace: Colorspace.csRgb,
  clip: IRect(50, 50, 400, 300),
  alpha: true,
);
```

### Convenience Methods

```dart
// One-liner PNG export
File('page.png').writeAsBytesSync(page.renderToPng());

// One-liner JPEG export (configurable quality)
File('page.jpg').writeAsBytesSync(page.renderToJpeg(quality: 90));
```

### `Pixmap` Improvements

```dart
final pix = page.getPixmap();

// Crop to sub-region
final cropped = pix.crop(IRect(50, 50, 400, 300));

// Scale with bilinear interpolation
final thumb = pix.scale(150, 200);

// Save to file (actually works now — was broken in v1.0.0)
pix.save('output.png');
pix.save('output.jpg');
```

---

## New: Reactive State Management

v0.1.2 adds `DocumentController` — an [RxDart](https://pub.dev/packages/rxdart)-powered
state manager that tracks the open document, current page, zoom level, and
provides observable streams for building reactive UIs:

```dart
final ctrl = DocumentController();

// Open document
ctrl.openBytes(pdfBytes);

// Navigate
ctrl.nextPage();
ctrl.previousPage();
ctrl.goToPage(5);

// Zoom
ctrl.setZoom(2.0);
ctrl.zoomIn();
ctrl.zoomOut();

// Render + text extraction
final png  = ctrl.renderToPng();
final text = ctrl.getText();

// Subscribe to changes
ctrl.state$.listen((state) {
  print('Page ${state.currentPage + 1}/${state.pageCount}');
  print('Zoom: ${(state.zoom * 100).toInt()}%');
});

ctrl.dispose();
```

---

## New: Batch Operations

`BatchRenderer` processes multiple pages efficiently:

```dart
final doc   = DartMuPDF.openFile('report.pdf');
final batch = BatchRenderer(doc);

// Thumbnails
final thumbs = batch.renderThumbnails(maxDimension: 150);

// Full-text search across all pages
final hits = batch.searchAll('revenue');

// Export all pages to PNG
final pngs = batch.exportAllToPng();

doc.close();
```

---

## Summary of Changes

| Item | v1.0.0 | v0.1.2 |
|------|--------|--------|
| `Page.getPixmap()` | **Missing** | **Added** — full render with matrix, colorspace, clip, alpha |
| `Page.renderToPng()` | Missing | Added |
| `Page.renderToJpeg()` | Missing | Added |
| `Pixmap.save()` | No-op stub | Fixed — writes to disk |
| `Pixmap.crop()` | Missing | Added |
| `Pixmap.scale()` | Missing | Added — bilinear interpolation |
| `DocumentController` | N/A | New — RxDart reactive state |
| `BatchRenderer` | N/A | New — bulk page operations |
| `rxdart` dependency | Not used | Added (`^0.28.0`) |

---

## How to Upgrade

```yaml
dependencies:
  dart_mupdf_donut: ^0.1.2
```

```bash
dart pub get
```

No breaking changes — all existing code continues to work.  The new methods
are purely additive.

---

*Last updated: 2025*
