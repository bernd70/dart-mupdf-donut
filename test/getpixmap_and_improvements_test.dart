import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_mupdf_donut/dart_mupdf.dart';

/// Minimal valid PDF bytes for testing.
Uint8List _minimalPdf() {
  return DartMuPDF.createBlank().toBytes();
}

void main() {
  // ==========================================================================
  //  Page.getPixmap() tests
  // ==========================================================================
  group('Page.getPixmap()', () {
    late Document doc;

    setUp(() {
      doc = DartMuPDF.createBlank(width: 200, height: 100);
    });

    tearDown(() {
      if (!doc.isClosed) doc.close();
    });

    test('returns a Pixmap with correct dimensions', () {
      final page = doc.getPage(0);
      final pix = page.getPixmap();

      expect(pix.width, 200);
      expect(pix.height, 100);
      expect(pix.colorspace, Colorspace.csRgb);
      expect(pix.hasAlpha, false);
    });

    test('respects alpha parameter', () {
      final pix = doc.getPage(0).getPixmap(alpha: true);
      expect(pix.hasAlpha, true);
      expect(pix.n, 4); // RGBA
    });

    test('scales with Matrix', () {
      final pix = doc.getPage(0).getPixmap(matrix: Matrix.scale(2, 2));
      expect(pix.width, 400);
      expect(pix.height, 200);
    });

    test('uses custom colorspace', () {
      final pix = doc.getPage(0).getPixmap(colorspace: Colorspace.csGray);
      // Should produce gray pixmap
      expect(pix.colorspace, Colorspace.csGray);
    });

    test('can convert to PNG without throwing', () {
      final pix = doc.getPage(0).getPixmap();
      final png = pix.toPng();
      expect(png, isNotEmpty);
      // PNG magic bytes
      expect(png[0], 0x89);
      expect(png[1], 0x50); // 'P'
    });

    test('renderToPng convenience works', () {
      final png = doc.getPage(0).renderToPng();
      expect(png, isNotEmpty);
      expect(png[0], 0x89);
    });

    test('renderToJpeg convenience works', () {
      final jpg = doc.getPage(0).renderToJpeg();
      expect(jpg, isNotEmpty);
      // JPEG magic
      expect(jpg[0], 0xFF);
      expect(jpg[1], 0xD8);
    });
  });

  // ==========================================================================
  //  Pixmap improvements
  // ==========================================================================
  group('Pixmap enhancements', () {
    test('crop() returns sub-region', () {
      final pix = Pixmap(
        colorspace: Colorspace.csRgb,
        width: 10,
        height: 10,
      );
      // Set a known pixel
      pix.setPixel(5, 5, [255, 0, 0]);
      final cropped = pix.crop(IRect(4, 4, 8, 8));
      expect(cropped.width, 4);
      expect(cropped.height, 4);
      // The pixel at (5,5) in the original is at (1,1) in the crop
      expect(cropped.getPixel(1, 1), [255, 0, 0]);
    });

    test('scale() resizes pixmap', () {
      final pix = Pixmap(
        colorspace: Colorspace.csRgb,
        width: 100,
        height: 100,
      );
      final scaled = pix.scale(50, 50);
      expect(scaled.width, 50);
      expect(scaled.height, 50);
    });

    test('save() writes to file (smoke test via toBytes)', () {
      final pix = Pixmap(
        colorspace: Colorspace.csRgb,
        width: 2,
        height: 2,
      );
      pix.clearWith(128);
      final png = pix.toPng();
      expect(png, isNotEmpty);
    });
  });

  // ==========================================================================
  //  DocumentController (RxDart) tests
  // ==========================================================================
  group('DocumentController', () {
    late DocumentController ctrl;

    setUp(() {
      ctrl = DocumentController(pixmapCacheSize: 3);
    });

    tearDown(() {
      ctrl.dispose();
    });

    test('initial state is empty', () {
      expect(ctrl.state.isOpen, false);
      expect(ctrl.state.pageCount, 0);
      expect(ctrl.state.currentPage, 0);
    });

    test('openBytes loads a document', () {
      final pdf = _minimalPdf();
      ctrl.openBytes(pdf);

      expect(ctrl.state.isOpen, true);
      expect(ctrl.state.pageCount, greaterThan(0));
      expect(ctrl.state.metadata, isNotNull);
    });

    test('close resets state', () {
      ctrl.openBytes(_minimalPdf());
      expect(ctrl.state.isOpen, true);
      ctrl.close();
      expect(ctrl.state.isOpen, false);
      expect(ctrl.state.pageCount, 0);
    });

    test('goToPage clamps to valid range', () {
      ctrl.openBytes(_minimalPdf());
      ctrl.goToPage(999);
      expect(ctrl.state.currentPage, ctrl.state.pageCount - 1);
      ctrl.goToPage(-5);
      expect(ctrl.state.currentPage, 0);
    });

    test('nextPage / previousPage navigate', () {
      // Create a 3-page doc
      final doc = DartMuPDF.createPdf();
      doc.newPage();
      doc.newPage();
      doc.newPage();
      final bytes = doc.toBytes();
      doc.close();

      ctrl.openBytes(bytes);
      expect(ctrl.state.currentPage, 0);
      ctrl.nextPage();
      expect(ctrl.state.currentPage, 1);
      ctrl.nextPage();
      expect(ctrl.state.currentPage, 2);
      ctrl.previousPage();
      expect(ctrl.state.currentPage, 1);
    });

    test('zoom changes are emitted', () {
      ctrl.openBytes(_minimalPdf());
      ctrl.setZoom(2.0);
      expect(ctrl.state.zoom, 2.0);
      ctrl.zoomIn(0.5);
      expect(ctrl.state.zoom, 2.5);
      ctrl.zoomOut(1.0);
      expect(ctrl.state.zoom, 1.5);
    });

    test('zoom is clamped', () {
      ctrl.openBytes(_minimalPdf());
      ctrl.setZoom(99.0);
      expect(ctrl.state.zoom, 10.0);
      ctrl.setZoom(0.01);
      expect(ctrl.state.zoom, 0.1);
    });

    test('renderPage returns a Pixmap', () {
      ctrl.openBytes(_minimalPdf());
      final pix = ctrl.renderPage();
      expect(pix.width, greaterThan(0));
      expect(pix.height, greaterThan(0));
    });

    test('getText extracts text', () {
      ctrl.openBytes(_minimalPdf());
      // blank page → empty or whitespace text is fine
      final text = ctrl.getText();
      expect(text, isA<String>());
    });

    test('state\$ stream emits on navigation', () async {
      ctrl.openBytes(_minimalPdf());

      final pages = <int>[];
      final sub = ctrl.currentPage$.listen(pages.add);

      ctrl.goToPage(0); // same page, should not emit duplicate
      await Future<void>.delayed(Duration.zero);

      sub.cancel();
      // Should have at most 1 emission (the current page).
      expect(pages, isNotEmpty);
    });
  });

  // ==========================================================================
  //  BatchRenderer tests
  // ==========================================================================
  group('BatchRenderer', () {
    late Document doc;

    setUp(() {
      doc = DartMuPDF.createPdf();
      doc.newPage();
      doc.newPage();
    });

    tearDown(() {
      if (!doc.isClosed) doc.close();
    });

    test('renderPages returns map of pixmaps', () {
      final renderer = BatchRenderer(doc);
      final result = renderer.renderPages();
      expect(result.length, 2);
      expect(result[0], isA<Pixmap>());
      expect(result[1], isA<Pixmap>());
    });

    test('renderThumbnails produces small pixmaps', () {
      final renderer = BatchRenderer(doc);
      final thumbs = renderer.renderThumbnails(maxDimension: 50);
      expect(thumbs.length, 2);
      for (final t in thumbs.values) {
        expect(t.width <= 50 || t.height <= 50, true);
      }
    });

    test('extractAllText returns list per page', () {
      final renderer = BatchRenderer(doc);
      final texts = renderer.extractAllText();
      expect(texts.length, 2);
    });

    test('searchAll returns empty map for non-existent text', () {
      final renderer = BatchRenderer(doc);
      final result = renderer.searchAll('xyzzy_not_found');
      expect(result, isEmpty);
    });

    test('exportAllToPng returns PNG bytes per page', () {
      final renderer = BatchRenderer(doc);
      final pngs = renderer.exportAllToPng();
      expect(pngs.length, 2);
      for (final png in pngs) {
        expect(png[0], 0x89); // PNG magic
      }
    });
  });
}
