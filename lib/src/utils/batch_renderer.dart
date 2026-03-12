import 'dart:typed_data';

import '../document.dart';
import '../pixmap.dart';
import '../geometry/matrix.dart';
import '../models/colorspace.dart';

/// Batch rendering utilities for efficient multi-page operations.
///
/// Use these helpers when you need to process many pages at once
/// (e.g. thumbnails, full-text extraction, PDF-to-image export).
class BatchRenderer {
  final Document document;

  BatchRenderer(this.document);

  /// Render a range of pages to [Pixmap]s.
  ///
  /// [from] and [to] are inclusive, 0-based page indices.
  /// Returns a map of page-index → Pixmap.
  Map<int, Pixmap> renderPages({
    int from = 0,
    int? to,
    Matrix? matrix,
    Colorspace? colorspace,
    bool alpha = false,
  }) {
    final endPage =
        (to ?? document.pageCount - 1).clamp(0, document.pageCount - 1);
    final results = <int, Pixmap>{};
    for (var i = from; i <= endPage; i++) {
      results[i] = document.getPage(i).getPixmap(
            matrix: matrix,
            colorspace: colorspace,
            alpha: alpha,
          );
    }
    return results;
  }

  /// Generate thumbnail pixmaps for a range of pages.
  ///
  /// [maxDimension] is the maximum width or height of each thumb.
  Map<int, Pixmap> renderThumbnails({
    int from = 0,
    int? to,
    int maxDimension = 150,
  }) {
    final endPage =
        (to ?? document.pageCount - 1).clamp(0, document.pageCount - 1);
    final results = <int, Pixmap>{};
    for (var i = from; i <= endPage; i++) {
      final page = document.getPage(i);
      final r = page.rect;
      final scale = maxDimension / (r.width > r.height ? r.width : r.height);
      results[i] = page.getPixmap(matrix: Matrix.scale(scale, scale));
    }
    return results;
  }

  /// Extract text from every page and return as a list.
  List<String> extractAllText() {
    return List.generate(
      document.pageCount,
      (i) => document.getPage(i).getText(),
    );
  }

  /// Search for [query] across all pages.
  ///
  /// Returns a map of page-index → list of match rectangles.
  Map<int, List<dynamic>> searchAll(String query) {
    final results = <int, List<dynamic>>{};
    for (var i = 0; i < document.pageCount; i++) {
      final hits = document.getPage(i).searchFor(query);
      if (hits.isNotEmpty) results[i] = hits;
    }
    return results;
  }

  /// Export all pages to PNG bytes.
  ///
  /// Returns a list of PNG-encoded [Uint8List], one per page.
  List<Uint8List> exportAllToPng({Matrix? matrix}) {
    return List.generate(
      document.pageCount,
      (i) => document.getPage(i).renderToPng(matrix: matrix),
    );
  }
}
