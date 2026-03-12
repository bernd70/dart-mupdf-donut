import 'dart:async';
import 'dart:typed_data';

import 'package:rxdart/rxdart.dart';

import '../document.dart';
import '../page.dart';
import '../pixmap.dart';
import '../geometry/matrix.dart';
import '../geometry/irect.dart';
import '../models/colorspace.dart';
import '../models/metadata.dart';
import '../models/toc_entry.dart';

// ---------------------------------------------------------------------------
//  Immutable state snapshot
// ---------------------------------------------------------------------------

/// Immutable snapshot of the reactive document state.
///
/// Emitted by [DocumentController.state$] every time something changes.
class DocumentState {
  /// The underlying document (may be `null` before opening).
  final Document? document;

  /// Currently selected page index (0-based).
  final int currentPage;

  /// Total number of pages.
  final int pageCount;

  /// Whether a background operation (load / render) is running.
  final bool isLoading;

  /// Last error, if any.
  final Object? error;

  /// Cached metadata.
  final PdfMetadata? metadata;

  /// Table of contents.
  final List<TocEntry> toc;

  /// Current zoom level (1.0 = 100 %).
  final double zoom;

  const DocumentState({
    this.document,
    this.currentPage = 0,
    this.pageCount = 0,
    this.isLoading = false,
    this.error,
    this.metadata,
    this.toc = const [],
    this.zoom = 1.0,
  });

  DocumentState copyWith({
    Document? document,
    int? currentPage,
    int? pageCount,
    bool? isLoading,
    Object? error,
    PdfMetadata? metadata,
    List<TocEntry>? toc,
    double? zoom,
  }) {
    return DocumentState(
      document: document ?? this.document,
      currentPage: currentPage ?? this.currentPage,
      pageCount: pageCount ?? this.pageCount,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      metadata: metadata ?? this.metadata,
      toc: toc ?? this.toc,
      zoom: zoom ?? this.zoom,
    );
  }

  /// Whether a document is currently open.
  bool get isOpen => document != null && !(document!.isClosed);
}

// ---------------------------------------------------------------------------
//  DocumentController — reactive layer around [Document]
// ---------------------------------------------------------------------------

/// Reactive wrapper around [Document] using RxDart.
///
/// All mutations go through methods that update an immutable
/// [DocumentState] emitted via [state$].  Consumers can also
/// subscribe to fine-grained streams such as [currentPage$],
/// [pageCount$] and [pixmap$] for targeted rebuilds.
///
/// ```dart
/// final controller = DocumentController();
/// controller.state$.listen((s) => print('Page ${s.currentPage}'));
///
/// controller.openBytes(pdfBytes);
/// controller.goToPage(3);
/// final pix = await controller.renderPage();
/// controller.dispose();
/// ```
class DocumentController {
  // ---- internal state subject ----
  final BehaviorSubject<DocumentState> _state$ =
      BehaviorSubject<DocumentState>.seeded(const DocumentState());

  // ---- pixmap render cache ----
  final Map<int, Pixmap> _pixmapCache = {};
  int _pixmapCacheMaxSize;

  /// Creates a [DocumentController].
  ///
  /// [pixmapCacheSize] controls how many rendered pages are kept in memory.
  DocumentController({int pixmapCacheSize = 10})
      : _pixmapCacheMaxSize = pixmapCacheSize;

  // ---------- Streams ----------

  /// Full state stream (distinct, never errors).
  ValueStream<DocumentState> get state$ => _state$.stream;

  /// Current state snapshot.
  DocumentState get state => _state$.value;

  /// Stream of the currently selected page index.
  Stream<int> get currentPage$ => _state$.map((s) => s.currentPage).distinct();

  /// Stream of the total page count.
  Stream<int> get pageCount$ => _state$.map((s) => s.pageCount).distinct();

  /// Stream of the loading flag.
  Stream<bool> get isLoading$ => _state$.map((s) => s.isLoading).distinct();

  /// Stream of errors (only non-null values).
  Stream<Object> get errors$ =>
      _state$.map((s) => s.error).whereType<Object>().distinct();

  /// Stream of zoom level changes.
  Stream<double> get zoom$ => _state$.map((s) => s.zoom).distinct();

  // ---------- Document lifecycle ----------

  /// Open a PDF from raw bytes.
  void openBytes(Uint8List bytes) {
    _closeInternal();
    try {
      _emit(_state$.value.copyWith(isLoading: true, error: null));
      final doc = Document.openBytes(bytes);
      _emit(DocumentState(
        document: doc,
        currentPage: 0,
        pageCount: doc.pageCount,
        metadata: doc.metadata,
        toc: doc.getToc(),
        zoom: _state$.value.zoom,
      ));
    } catch (e) {
      _emit(_state$.value.copyWith(isLoading: false, error: e));
    }
  }

  /// Open a PDF from a file path.
  void openFile(String path) {
    _closeInternal();
    try {
      _emit(_state$.value.copyWith(isLoading: true, error: null));
      final doc = Document.openFile(path);
      _emit(DocumentState(
        document: doc,
        currentPage: 0,
        pageCount: doc.pageCount,
        metadata: doc.metadata,
        toc: doc.getToc(),
        zoom: _state$.value.zoom,
      ));
    } catch (e) {
      _emit(_state$.value.copyWith(isLoading: false, error: e));
    }
  }

  /// Close the current document and reset state.
  void close() {
    _closeInternal();
    _emit(const DocumentState());
  }

  void _closeInternal() {
    _pixmapCache.clear();
    final doc = _state$.value.document;
    if (doc != null && !doc.isClosed) {
      doc.close();
    }
  }

  // ---------- Navigation ----------

  /// Navigate to a specific page (0-based).
  void goToPage(int page) {
    final s = _state$.value;
    if (!s.isOpen) return;
    final clamped = page.clamp(0, s.pageCount - 1);
    if (clamped != s.currentPage) {
      _emit(s.copyWith(currentPage: clamped));
    }
  }

  /// Go to the next page.
  void nextPage() => goToPage(state.currentPage + 1);

  /// Go to the previous page.
  void previousPage() => goToPage(state.currentPage - 1);

  /// Go to the first page.
  void firstPage() => goToPage(0);

  /// Go to the last page.
  void lastPage() => goToPage(state.pageCount - 1);

  // ---------- Zoom ----------

  /// Set zoom level (1.0 = 100 %).
  void setZoom(double zoom) {
    final clamped = zoom.clamp(0.1, 10.0);
    if (clamped != _state$.value.zoom) {
      _pixmapCache.clear(); // zoom changed, invalidate cache
      _emit(_state$.value.copyWith(zoom: clamped));
    }
  }

  /// Zoom in by [step] (default 0.25).
  void zoomIn([double step = 0.25]) => setZoom(state.zoom + step);

  /// Zoom out by [step] (default 0.25).
  void zoomOut([double step = 0.25]) => setZoom(state.zoom - step);

  // ---------- Rendering ----------

  /// Render the current (or given) page to a [Pixmap].
  ///
  /// Uses an internal LRU cache so repeated renders of the same page at
  /// the same zoom level are essentially free.
  Pixmap renderPage({
    int? pageNumber,
    Colorspace? colorspace,
    IRect? clip,
    bool alpha = false,
  }) {
    final s = _state$.value;
    if (!s.isOpen) throw StateError('No document is open');
    final pn = pageNumber ?? s.currentPage;
    final cacheKey = pn;

    if (_pixmapCache.containsKey(cacheKey)) {
      return _pixmapCache[cacheKey]!;
    }

    final page = s.document!.getPage(pn);
    final mat = Matrix.scale(s.zoom, s.zoom);
    final pixmap = page.getPixmap(
      matrix: mat,
      colorspace: colorspace,
      clip: clip,
      alpha: alpha,
    );

    // LRU eviction
    if (_pixmapCache.length >= _pixmapCacheMaxSize) {
      _pixmapCache.remove(_pixmapCache.keys.first);
    }
    _pixmapCache[cacheKey] = pixmap;
    return pixmap;
  }

  /// Render the current page to PNG bytes.
  Uint8List renderToPng({int? pageNumber, bool alpha = false}) {
    return renderPage(pageNumber: pageNumber, alpha: alpha).toPng();
  }

  // ---------- Text ----------

  /// Extract text from the current (or given) page.
  String getText({int? pageNumber}) {
    final s = _state$.value;
    if (!s.isOpen) throw StateError('No document is open');
    return s.document!.getPage(pageNumber ?? s.currentPage).getText();
  }

  /// Extract text from all pages, concatenated.
  String getFullText({String separator = '\n\n'}) {
    final s = _state$.value;
    if (!s.isOpen) throw StateError('No document is open');
    return List.generate(
      s.pageCount,
      (i) => s.document!.getPage(i).getText(),
    ).join(separator);
  }

  // ---------- Page access shortcut ----------

  /// Get the [Page] object for the current (or given) page.
  Page getPage([int? pageNumber]) {
    final s = _state$.value;
    if (!s.isOpen) throw StateError('No document is open');
    return s.document!.getPage(pageNumber ?? s.currentPage);
  }

  // ---------- Internals ----------

  void _emit(DocumentState newState) {
    if (!_state$.isClosed) _state$.add(newState);
  }

  /// Release all resources.  The controller must not be used after this.
  void dispose() {
    _closeInternal();
    _state$.close();
  }
}
