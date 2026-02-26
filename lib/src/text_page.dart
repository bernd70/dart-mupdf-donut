import 'dart:convert';
import 'dart:math' as math;

import 'core/pdf_objects.dart';
import 'core/pdf_parser.dart';
import 'page.dart';
import 'geometry/rect.dart';
import 'models/text_block.dart';
import 'models/text_word.dart';
import 'models/text_dict.dart';

/// Parsed text run within a content stream.
class _TextRun {
  final String text;
  final double x;
  final double y;
  final double fontSize;
  final String fontName;
  final double charSpace;
  final double wordSpace;
  final double horizontalScale;

  _TextRun({
    required this.text,
    required this.x,
    required this.y,
    required this.fontSize,
    required this.fontName,
    this.charSpace = 0,
    this.wordSpace = 0,
    this.horizontalScale = 100,
  });

  double get approxWidth {
    // Approximate width assuming 0.5 average character width factor
    return text.length * fontSize * 0.5 * (horizontalScale / 100.0);
  }
}

/// Represents a parsed text page, equivalent to PyMuPDF's `fitz.TextPage`.
///
/// Extracts text from the page content stream using the PDF text operators.
/// Supports output in multiple formats:
/// - Plain text
/// - Blocks (with bounding boxes)
/// - Words (with bounding boxes)
/// - Dict (nested structure)
/// - HTML
/// - XHTML
/// - XML
class TextPage {
  /// The page this text page was extracted from.
  final Page page;

  /// Extracted text runs from the content stream.
  final List<_TextRun> _textRuns = [];

  /// Cached blocks.
  List<TextBlock>? _blocks;

  /// Cached words.
  List<TextWord>? _words;

  TextPage._(this.page);

  /// Create a TextPage by parsing the page's content stream.
  factory TextPage.fromPage(Page page, PdfParser parser) {
    final textPage = TextPage._(page);
    textPage._parse(parser);
    return textPage;
  }

  /// The page rectangle.
  Rect get rect => page.rect;

  /// Debug: dump text runs with positions.
  List<Map<String, dynamic>> debugRuns() {
    return _textRuns
        .map((r) => {
              'text': r.text,
              'x': r.x,
              'y': r.y,
              'fontSize': r.fontSize,
              'fontName': r.fontName,
              'approxWidth': r.approxWidth,
            })
        .toList();
  }

  /// Extract plain text from the page.
  ///
  /// Equivalent to PyMuPDF's `textpage.extractText()`.
  String extractText() {
    if (_textRuns.isEmpty) return '';

    final sorted = List<_TextRun>.from(_textRuns)
      ..sort((a, b) {
        final dy = a.y.compareTo(b.y);
        if (dy != 0) return dy;
        return a.x.compareTo(b.x);
      });

    final buffer = StringBuffer();
    double lastY = double.negativeInfinity;
    double lastX = 0;
    final lineThreshold = 5.0;

    for (final run in sorted) {
      final text = run.text;
      if (text.isEmpty) continue;

      if ((run.y - lastY).abs() > lineThreshold) {
        // New line
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(text);
      } else {
        // Same line — check x gap to decide if space is needed
        final gap = run.x - lastX;
        final spaceWidth = run.fontSize * 0.25;
        if (gap > spaceWidth && !text.startsWith(' ')) {
          buffer.write(' ');
        }
        buffer.write(text);
      }
      lastY = run.y;
      lastX = run.x + run.approxWidth;
    }

    // PyMuPDF always appends a trailing newline
    buffer.write('\n');
    return buffer.toString();
  }

  /// Extract text as blocks with bounding boxes.
  ///
  /// Equivalent to PyMuPDF's `textpage.extractBLOCKS()`.
  List<TextBlock> extractBlocks() {
    if (_blocks != null) return _blocks!;

    final runs = List<_TextRun>.from(_textRuns)
      ..sort((a, b) {
        final dy = a.y.compareTo(b.y);
        if (dy != 0) return dy;
        return a.x.compareTo(b.x);
      });

    final blocks = <TextBlock>[];
    if (runs.isEmpty) {
      _blocks = blocks;
      return blocks;
    }

    // First build lines from runs (same joining logic as extractText)
    final lineThreshold = 5.0;
    final linesList = <List<_TextRun>>[];
    var curLine = <_TextRun>[runs.first];
    double lastY = runs.first.y;
    double lastX = runs.first.x + runs.first.approxWidth;

    for (int i = 1; i < runs.length; i++) {
      final run = runs[i];
      if (run.text.isEmpty) continue;

      if ((run.y - lastY).abs() > lineThreshold) {
        if (curLine.isNotEmpty) linesList.add(curLine);
        curLine = [run];
      } else {
        curLine.add(run);
      }
      lastY = run.y;
      lastX = run.x + run.approxWidth;
    }
    if (curLine.isNotEmpty) linesList.add(curLine);

    if (linesList.isEmpty) {
      _blocks = blocks;
      return blocks;
    }

    // Helper: get dominant font of a line (first non-space run's font)
    String lineDominantFont(List<_TextRun> lineRuns) {
      for (final r in lineRuns) {
        if (r.text.trim().isNotEmpty) return r.fontName;
      }
      return lineRuns.first.fontName;
    }

    // Helper: get line text respecting x-gaps
    String buildLineText(List<_TextRun> lineRuns) {
      if (lineRuns.isEmpty) return '';
      final buf = StringBuffer(lineRuns.first.text);
      double lx = lineRuns.first.x + lineRuns.first.approxWidth;
      for (int i = 1; i < lineRuns.length; i++) {
        final r = lineRuns[i];
        final gap = r.x - lx;
        final spaceWidth = r.fontSize * 0.25;
        if (gap > spaceWidth && !r.text.startsWith(' ')) {
          buf.write(' ');
        }
        buf.write(r.text);
        lx = r.x + r.approxWidth;
      }
      return buf.toString();
    }

    // Group lines into blocks. Split on:
    // 1. Large y-gap (> typical line spacing * 1.5)
    // 2. Font change at line start
    int blockNum = 0;
    double blockX0 = linesList.first.first.x;
    double blockY0 = linesList.first.first.y;
    double blockX1 = linesList.first.last.x + linesList.first.last.approxWidth;
    double blockY1 = linesList.first.first.y + linesList.first.first.fontSize;
    final blockText = StringBuffer(buildLineText(linesList.first));
    String prevFont = lineDominantFont(linesList.first);
    double prevY = linesList.first.first.y;

    for (int i = 1; i < linesList.length; i++) {
      final lineRuns = linesList[i];
      final lineY = lineRuns.first.y;
      final lineFontSize = lineRuns.first.fontSize;
      final lineFont = lineDominantFont(lineRuns);
      final yGap = (lineY - prevY).abs();

      // Detect block breaks
      final largeGap = yGap > lineFontSize * 2.0; // paragraph break
      final fontChanged = lineFont != prevFont;

      if (largeGap || fontChanged) {
        // Close current block
        blocks.add(TextBlock(
          x0: blockX0,
          y0: blockY0,
          x1: blockX1,
          y1: blockY1,
          text: blockText.toString(),
          blockNumber: blockNum,
          blockType: 0,
        ));
        blockNum++;
        // Start new block
        blockX0 = lineRuns.first.x;
        blockY0 = lineY;
        blockX1 = lineRuns.last.x + lineRuns.last.approxWidth;
        blockY1 = lineY + lineFontSize;
        blockText.clear();
        blockText.write(buildLineText(lineRuns));
      } else {
        // Continue current block
        blockText.write('\n');
        blockText.write(buildLineText(lineRuns));
        for (final r in lineRuns) {
          blockX0 = math.min(blockX0, r.x);
          blockX1 = math.max(blockX1, r.x + r.approxWidth);
        }
        blockY0 = math.min(blockY0, lineY);
        blockY1 = math.max(blockY1, lineY + lineFontSize);
      }

      prevFont = lineFont;
      prevY = lineY;
    }

    // Last block
    blocks.add(TextBlock(
      x0: blockX0,
      y0: blockY0,
      x1: blockX1,
      y1: blockY1,
      text: blockText.toString(),
      blockNumber: blockNum,
      blockType: 0,
    ));

    _blocks = blocks;
    return blocks;
  }

  /// Extract words with bounding boxes.
  ///
  /// Equivalent to PyMuPDF's `textpage.extractWORDS()`.
  List<TextWord> extractWords() {
    if (_words != null) return _words!;

    final words = <TextWord>[];

    if (_textRuns.isEmpty) {
      _words = words;
      return words;
    }

    final runs = List<_TextRun>.from(_textRuns)
      ..sort((a, b) {
        final dy = a.y.compareTo(b.y);
        if (dy != 0) return dy;
        return a.x.compareTo(b.x);
      });

    // Build lines by joining runs (same logic as extractText)
    final lineThreshold = 5.0;
    // Each line: list of (text, x, y, fontSize, approxWidth) segments
    final lines = <List<_TextRun>>[];
    var currentLine = <_TextRun>[];

    double lastY = double.negativeInfinity;
    double lastX = 0;

    for (final run in runs) {
      if (run.text.isEmpty) continue;

      if ((run.y - lastY).abs() > lineThreshold) {
        // New line
        if (currentLine.isNotEmpty) lines.add(currentLine);
        currentLine = [run];
      } else {
        // Same line — check if gap requires a space (same as extractText logic)
        final gap = run.x - lastX;
        final spaceWidth = run.fontSize * 0.25;
        if (gap > spaceWidth && !run.text.startsWith(' ')) {
          // Insert a synthetic space run
          currentLine.add(_TextRun(
            text: ' ',
            x: lastX,
            y: run.y,
            fontSize: run.fontSize,
            fontName: run.fontName,
          ));
        }
        currentLine.add(run);
      }
      lastY = run.y;
      lastX = run.x + run.approxWidth;
    }
    if (currentLine.isNotEmpty) lines.add(currentLine);

    // Now extract words from each line
    int blockN = 0;
    int lineN = 0;
    int wordN = 0;
    double prevLineY = double.negativeInfinity;

    for (final lineRuns in lines) {
      if (lineRuns.isEmpty) continue;
      final lineY = lineRuns.first.y;
      final lineFontSize = lineRuns.first.fontSize;

      if ((lineY - prevLineY).abs() > lineFontSize * 1.5) {
        blockN++;
        lineN = 0;
        wordN = 0;
      } else {
        lineN++;
        wordN = 0;
      }

      // Concatenate all run text in this line
      final lineText = StringBuffer();
      // Track char-to-position mapping for bounding boxes
      final charPositions = <double>[]; // x position of each char
      final charFontSizes = <double>[]; // font size at each char

      for (final run in lineRuns) {
        final charWidth = run.approxWidth / math.max(run.text.length, 1);
        for (int i = 0; i < run.text.length; i++) {
          charPositions.add(run.x + i * charWidth);
          charFontSizes.add(run.fontSize);
        }
        lineText.write(run.text);
      }

      // Split concatenated line into words
      final fullText = lineText.toString();
      final wordPattern = RegExp(r'\S+');
      for (final match in wordPattern.allMatches(fullText)) {
        final word = match.group(0)!;
        final startIdx = match.start;
        final endIdx = match.end - 1;

        final x0 = startIdx < charPositions.length
            ? charPositions[startIdx]
            : lineRuns.first.x;
        final x1End = endIdx < charPositions.length
            ? charPositions[endIdx]
            : charPositions.last;
        final fs = startIdx < charFontSizes.length
            ? charFontSizes[startIdx]
            : lineFontSize;
        final charW = fs * 0.5;

        words.add(TextWord(
          x0: x0,
          y0: lineY,
          x1: x1End + charW,
          y1: lineY + fs,
          word: word,
          blockNumber: blockN,
          lineNumber: lineN,
          wordNumber: wordN,
        ));
        wordN++;
      }

      prevLineY = lineY;
    }

    _words = words;
    return words;
  }

  /// Extract text as a detailed dictionary.
  ///
  /// Equivalent to PyMuPDF's `textpage.extractDICT()`.
  TextDict extractDict({bool raw = false}) {
    final blocks = <TextDictBlock>[];
    final allRuns = List<_TextRun>.from(_textRuns)
      ..sort((a, b) {
        final dy = a.y.compareTo(b.y);
        if (dy != 0) return dy;
        return a.x.compareTo(b.x);
      });

    if (allRuns.isEmpty) {
      return TextDict(
        width: rect.width,
        height: rect.height,
        blocks: [],
      );
    }

    // Group runs into blocks (by larger Y gaps)
    final blockGroups = <List<_TextRun>>[];
    var currentGroup = <_TextRun>[allRuns.first];
    for (int i = 1; i < allRuns.length; i++) {
      final run = allRuns[i];
      final prevRun = allRuns[i - 1];
      if ((run.y - prevRun.y).abs() > prevRun.fontSize * 1.5) {
        blockGroups.add(currentGroup);
        currentGroup = <_TextRun>[run];
      } else {
        currentGroup.add(run);
      }
    }
    blockGroups.add(currentGroup);

    int blockNum = 0;
    for (final group in blockGroups) {
      // Group into lines
      final lineGroups = <List<_TextRun>>[];
      var lineGroup = <_TextRun>[group.first];
      for (int i = 1; i < group.length; i++) {
        if ((group[i].y - group[i - 1].y).abs() > 5) {
          lineGroups.add(lineGroup);
          lineGroup = <_TextRun>[group[i]];
        } else {
          lineGroup.add(group[i]);
        }
      }
      lineGroups.add(lineGroup);

      final lines = <TextDictLine>[];
      double bx0 = double.infinity, by0 = double.infinity;
      double bx1 = double.negativeInfinity, by1 = double.negativeInfinity;

      for (final line in lineGroups) {
        final spans = <TextDictSpan>[];
        double lx0 = double.infinity, ly0 = double.infinity;
        double lx1 = double.negativeInfinity, ly1 = double.negativeInfinity;

        for (final run in line) {
          final chars = <TextDictChar>[];
          if (raw) {
            double cx = run.x;
            final cw = run.approxWidth / math.max(run.text.length, 1);
            for (int j = 0; j < run.text.length; j++) {
              chars.add(TextDictChar(
                origin: Rect(cx, run.y, cx + cw, run.y + run.fontSize),
                bbox: Rect(cx, run.y, cx + cw, run.y + run.fontSize),
                c: run.text.codeUnitAt(j),
              ));
              cx += cw;
            }
          }

          final sRect = Rect(
            run.x,
            run.y,
            run.x + run.approxWidth,
            run.y + run.fontSize,
          );

          spans.add(TextDictSpan(
            size: run.fontSize,
            flags: 0,
            font: run.fontName,
            color: 0,
            ascender: run.fontSize * 0.8,
            descender: -run.fontSize * 0.2,
            text: run.text,
            origin: Rect(
                run.x, run.y, run.x + run.approxWidth, run.y + run.fontSize),
            bbox: sRect,
            chars: raw ? chars : [],
          ));

          lx0 = math.min(lx0, sRect.x0);
          ly0 = math.min(ly0, sRect.y0);
          lx1 = math.max(lx1, sRect.x1);
          ly1 = math.max(ly1, sRect.y1);
        }

        final lineBbox = Rect(lx0, ly0, lx1, ly1);
        lines.add(TextDictLine(
          spans: spans,
          wmode: const Point2D(0, 0),
          dir: const Point2D(1, 0),
          bbox: lineBbox,
        ));

        bx0 = math.min(bx0, lx0);
        by0 = math.min(by0, ly0);
        bx1 = math.max(bx1, lx1);
        by1 = math.max(by1, ly1);
      }

      blocks.add(TextDictBlock(
        number: blockNum,
        type: 0,
        bbox: Rect(bx0, by0, bx1, by1),
        lines: lines,
      ));
      blockNum++;
    }

    return TextDict(
      width: rect.width,
      height: rect.height,
      blocks: blocks,
    );
  }

  /// Extract text as HTML.
  ///
  /// Equivalent to PyMuPDF's `textpage.extractHTML()`.
  String extractHtml() {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html><head><meta charset="utf-8"></head><body>');

    final blocks = extractBlocks();
    for (final block in blocks) {
      buffer.write('<p>');
      buffer.write(_escapeHtml(block.text));
      buffer.writeln('</p>');
    }

    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  /// Extract text as XHTML.
  String extractXhtml() {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<html xmlns="http://www.w3.org/1999/xhtml">');
    buffer.writeln('<head><title></title></head><body>');

    final blocks = extractBlocks();
    for (final block in blocks) {
      buffer.write('<p>');
      buffer.write(_escapeHtml(block.text));
      buffer.writeln('</p>');
    }

    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  /// Extract text as XML.
  String extractXml() {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<page width="${rect.width}" height="${rect.height}">');

    final blocks = extractBlocks();
    for (final block in blocks) {
      buffer.write('<block bbox="${block.x0},${block.y0},');
      buffer.write('${block.x1},${block.y1}">');
      buffer.write('<line>');
      buffer.write(_escapeHtml(block.text));
      buffer.write('</line>');
      buffer.writeln('</block>');
    }

    buffer.writeln('</page>');
    return buffer.toString();
  }

  String _escapeHtml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  // ---------- Internal Parsing ----------

  void _parse(PdfParser parser) {
    final contentData = page.readContents();
    if (contentData.isEmpty) return;

    final content = latin1.decode(contentData);
    _parseContentStream(content);

    // Convert PDF coordinates (origin bottom-left, y up) to screen coordinates
    // (origin top-left, y down) like PyMuPDF does.
    final pageHeight = page.rect.height;
    for (int i = 0; i < _textRuns.length; i++) {
      final run = _textRuns[i];
      _textRuns[i] = _TextRun(
        text: run.text,
        x: run.x,
        y: pageHeight - run.y - run.fontSize,
        fontSize: run.fontSize,
        fontName: run.fontName,
        charSpace: run.charSpace,
        wordSpace: run.wordSpace,
        horizontalScale: run.horizontalScale,
      );
    }
  }

  void _parseContentStream(String content) {
    // PDF text extraction state machine
    double tfs = 12; // Text font size from Tf operator
    String fontName = 'default';
    var tm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]; // text matrix
    double tx = 0, ty = 0; // current text position
    double tl = 0; // text leading
    double charSpace = 0;
    double wordSpace = 0;
    double horizontalScale = 100;
    // ignore: unused_local_variable
    bool inText = false;

    // Current Transformation Matrix stack
    var ctm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
    final ctmStack = <List<double>>[];

    // Font ToUnicode maps (fontName -> map of charCode -> unicode)
    final fontUnicodeMaps = <String, Map<int, String>>{};

    // Track which fonts use 2-byte CID encoding (Type0/Identity-H)
    final fontIsCID = <String, bool>{};

    // Build font unicode maps from page resources
    _buildFontUnicodeMaps(fontUnicodeMaps, fontIsCID);

    final tokenizer = _ContentTokenizer(content);

    while (tokenizer.hasMore) {
      final token = tokenizer.nextToken();
      if (token == null) break;

      switch (token) {
        case 'q':
          ctmStack.add(List<double>.from(ctm));
          break;
        case 'Q':
          if (ctmStack.isNotEmpty) ctm = ctmStack.removeLast();
          break;
        case 'BT':
          inText = true;
          tm = [1, 0, 0, 1, 0, 0];
          tx = 0;
          ty = 0;
          break;
        case 'ET':
          inText = false;
          break;
        case 'Tf':
          // Set font: /fontName size Tf
          if (tokenizer.operands.length >= 2) {
            fontName = tokenizer.operands[tokenizer.operands.length - 2]
                .replaceFirst('/', '');
            tfs = _parseNum(tokenizer.operands.last);
          }
          break;
        case 'Td':
          // Move text position: tx ty Td
          if (tokenizer.operands.length >= 2) {
            final dx =
                _parseNum(tokenizer.operands[tokenizer.operands.length - 2]);
            final dy = _parseNum(tokenizer.operands.last);
            tx += dx;
            ty += dy;
            tm[4] = tx;
            tm[5] = ty;
          }
          break;
        case 'TD':
          // Move text position and set leading: tx ty TD
          if (tokenizer.operands.length >= 2) {
            final dx =
                _parseNum(tokenizer.operands[tokenizer.operands.length - 2]);
            final dy = _parseNum(tokenizer.operands.last);
            tl = -dy;
            tx += dx;
            ty += dy;
            tm[4] = tx;
            tm[5] = ty;
          }
          break;
        case 'Tm':
          // Set text matrix: a b c d e f Tm
          if (tokenizer.operands.length >= 6) {
            final ops = tokenizer.operands;
            final base = ops.length - 6;
            tm = [
              _parseNum(ops[base]),
              _parseNum(ops[base + 1]),
              _parseNum(ops[base + 2]),
              _parseNum(ops[base + 3]),
              _parseNum(ops[base + 4]),
              _parseNum(ops[base + 5]),
            ];
            tx = tm[4];
            ty = tm[5];
            // Note: Don't override tfs here. The effective font size is
            // tfs * |tm scaling factor|, computed when creating text runs.
          }
          break;
        case 'T*':
          // Move to start of next line
          tx = 0;
          ty -= tl;
          tm[4] = tx;
          tm[5] = ty;
          break;
        case 'TL':
          if (tokenizer.operands.isNotEmpty) {
            tl = _parseNum(tokenizer.operands.last);
          }
          break;
        case 'Tc':
          if (tokenizer.operands.isNotEmpty) {
            charSpace = _parseNum(tokenizer.operands.last);
          }
          break;
        case 'Tw':
          if (tokenizer.operands.isNotEmpty) {
            wordSpace = _parseNum(tokenizer.operands.last);
          }
          break;
        case 'Tz':
          if (tokenizer.operands.isNotEmpty) {
            horizontalScale = _parseNum(tokenizer.operands.last);
          }
          break;
        case 'Tj':
          // Show string: (string) Tj
          if (tokenizer.operands.isNotEmpty) {
            final rawStr = tokenizer.operands.last;
            final text = _decodeTextWithFont(
                rawStr, fontName, fontUnicodeMaps, fontIsCID);
            if (text.isNotEmpty) {
              // Effective font size = Tf size × text matrix scale
              final efs = tfs * tm[0].abs();
              final pos = _applyCtm(ctm, tm[4], tm[5]);
              _textRuns.add(_TextRun(
                text: text,
                x: pos[0],
                y: pos[1],
                fontSize: efs,
                fontName: fontName,
                charSpace: charSpace,
                wordSpace: wordSpace,
                horizontalScale: horizontalScale,
              ));
            }
          }
          break;
        case "'":
          // Move to next line and show string
          tx = 0;
          ty -= tl;
          tm[4] = tx;
          tm[5] = ty;
          if (tokenizer.operands.isNotEmpty) {
            final rawStr = tokenizer.operands.last;
            final text = _decodeTextWithFont(
                rawStr, fontName, fontUnicodeMaps, fontIsCID);
            if (text.isNotEmpty) {
              final efs = tfs * tm[0].abs();
              final pos = _applyCtm(ctm, tm[4], tm[5]);
              _textRuns.add(_TextRun(
                text: text,
                x: pos[0],
                y: pos[1],
                fontSize: efs,
                fontName: fontName,
              ));
            }
          }
          break;
        case '"':
          // Set word/char space, move to next line, show string
          if (tokenizer.operands.length >= 3) {
            wordSpace =
                _parseNum(tokenizer.operands[tokenizer.operands.length - 3]);
            charSpace =
                _parseNum(tokenizer.operands[tokenizer.operands.length - 2]);
            tx = 0;
            ty -= tl;
            tm[4] = tx;
            tm[5] = ty;
            final rawStr = tokenizer.operands.last;
            final text = _decodeTextWithFont(
                rawStr, fontName, fontUnicodeMaps, fontIsCID);
            if (text.isNotEmpty) {
              final efs = tfs * tm[0].abs();
              final pos = _applyCtm(ctm, tm[4], tm[5]);
              _textRuns.add(_TextRun(
                text: text,
                x: pos[0],
                y: pos[1],
                fontSize: efs,
                fontName: fontName,
                charSpace: charSpace,
                wordSpace: wordSpace,
              ));
            }
          }
          break;
        case 'TJ':
          // Show text array: [ (str1) num (str2) ... ] TJ
          if (tokenizer.lastArray != null) {
            final efs = tfs * tm[0].abs();
            final buffer = StringBuffer();
            double xOffset = 0;
            bool foundString = false;
            double firstStringOffset = 0;
            for (final elem in tokenizer.lastArray!) {
              if (elem is String) {
                if (!foundString) {
                  firstStringOffset = xOffset;
                  foundString = true;
                }
                buffer.write(_decodeTextWithFont(
                    elem, fontName, fontUnicodeMaps, fontIsCID));
              } else if (elem is num) {
                // Negative value moves right, positive moves left
                // Displacement in thousandths of text space units
                xOffset -= elem / 1000.0 * tfs;
              }
            }
            final text = buffer.toString();
            if (text.isNotEmpty) {
              // Use position of the first string element
              final pos = _applyCtm(ctm, tm[4] + firstStringOffset, tm[5]);
              _textRuns.add(_TextRun(
                text: text,
                x: pos[0],
                y: pos[1],
                fontSize: efs,
                fontName: fontName,
                charSpace: charSpace,
                wordSpace: wordSpace,
                horizontalScale: horizontalScale,
              ));
            }
          }
          break;
        case 'cm':
          // Concatenate matrix to CTM: a b c d e f cm
          if (tokenizer.operands.length >= 6) {
            final ops = tokenizer.operands;
            final base = ops.length - 6;
            final m = [
              _parseNum(ops[base]),
              _parseNum(ops[base + 1]),
              _parseNum(ops[base + 2]),
              _parseNum(ops[base + 3]),
              _parseNum(ops[base + 4]),
              _parseNum(ops[base + 5]),
            ];
            ctm = _multiplyMatrices(m, ctm);
          }
          break;
      }

      // Clear operands after consuming operator
      if (_isOperator(token)) {
        tokenizer.operands.clear();
        tokenizer.lastArray = null;
      }
    }
  }

  /// Apply CTM to a point (x, y).
  List<double> _applyCtm(List<double> ctm, double x, double y) {
    // If CTM is identity, skip computation
    if (ctm[0] == 1.0 &&
        ctm[1] == 0.0 &&
        ctm[2] == 0.0 &&
        ctm[3] == 1.0 &&
        ctm[4] == 0.0 &&
        ctm[5] == 0.0) {
      return [x, y];
    }
    return [
      ctm[0] * x + ctm[2] * y + ctm[4],
      ctm[1] * x + ctm[3] * y + ctm[5],
    ];
  }

  /// Multiply two 3x3 transformation matrices (stored as [a, b, c, d, e, f]).
  List<double> _multiplyMatrices(List<double> m1, List<double> m2) {
    return [
      m1[0] * m2[0] + m1[1] * m2[2],
      m1[0] * m2[1] + m1[1] * m2[3],
      m1[2] * m2[0] + m1[3] * m2[2],
      m1[2] * m2[1] + m1[3] * m2[3],
      m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
      m1[4] * m2[1] + m1[5] * m2[3] + m2[5],
    ];
  }

  /// Build ToUnicode maps for all fonts in page resources.
  void _buildFontUnicodeMaps(
    Map<String, Map<int, String>> maps,
    Map<String, bool> cidFonts,
  ) {
    try {
      final resources = page.pageDict.getDict('Resources');
      PdfDict? fontDict;

      if (resources != null) {
        fontDict = resources.getDict('Font');
        if (fontDict == null) {
          final fontRef = resources.getRef('Font');
          if (fontRef != null) {
            final resolved = page.parser.getObject(fontRef.objectNumber);
            fontDict = resolved?.dict;
          }
        }
      } else {
        // Try resolving resources ref
        final resRef = page.pageDict.getRef('Resources');
        if (resRef != null) {
          final resObj = page.parser.getObject(resRef.objectNumber);
          final resDict = resObj?.dict;
          if (resDict != null) {
            fontDict = resDict.getDict('Font');
            if (fontDict == null) {
              final fontRef = resDict.getRef('Font');
              if (fontRef != null) {
                final resolved = page.parser.getObject(fontRef.objectNumber);
                fontDict = resolved?.dict;
              }
            }
          }
        }
      }

      if (fontDict == null) return;

      for (final key in fontDict.keys) {
        final ref = fontDict.getRef(key);
        if (ref == null) continue;

        final fontObj = page.parser.getObject(ref.objectNumber);
        final fDict = fontObj?.dict;
        if (fDict == null) continue;

        // Detect Type0/CID fonts (2-byte encoding)
        final subtype = fDict['Subtype'];
        if (subtype is PdfName && subtype.value == 'Type0') {
          cidFonts[key] = true;
        }

        // Check for ToUnicode CMap
        final toUnicodeRef = fDict.getRef('ToUnicode');
        if (toUnicodeRef != null) {
          final cmapData = page.parser.getStreamData(toUnicodeRef.objectNumber);
          if (cmapData != null) {
            try {
              final cmapStr = latin1.decode(cmapData);
              maps[key] = _parseToUnicodeCMap(cmapStr);
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // Fail silently — font decoding is best-effort
    }
  }

  /// Parse a ToUnicode CMap to produce a charCode -> Unicode mapping.
  Map<int, String> _parseToUnicodeCMap(String cmap) {
    final result = <int, String>{};

    // Parse beginbfchar ... endbfchar sections
    final bfcharPattern = RegExp(
      r'beginbfchar\s+(.*?)\s*endbfchar',
      dotAll: true,
    );
    for (final match in bfcharPattern.allMatches(cmap)) {
      final section = match.group(1)!;
      final lines = section.trim().split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        final parts =
            RegExp(r'<([0-9a-fA-F]+)>\s+<([0-9a-fA-F]+)>').firstMatch(trimmed);
        if (parts != null) {
          final srcCode = int.parse(parts.group(1)!, radix: 16);
          final dstHex = parts.group(2)!;
          result[srcCode] = _hexToUnicode(dstHex);
        }
      }
    }

    // Parse beginbfrange ... endbfrange sections
    final bfrangePattern = RegExp(
      r'beginbfrange\s+(.*?)\s*endbfrange',
      dotAll: true,
    );
    for (final match in bfrangePattern.allMatches(cmap)) {
      final section = match.group(1)!;
      final lines = section.trim().split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        // Check array form FIRST: <srcCodeLo> <srcCodeHi> [<str0> <str1> ...]
        // Must check before simple range to avoid false match inside brackets
        final arrayParts = RegExp(
          r'<([0-9a-fA-F]+)>\s+<([0-9a-fA-F]+)>\s+\[(.+?)\]',
        ).firstMatch(trimmed);
        if (arrayParts != null) {
          final lo = int.parse(arrayParts.group(1)!, radix: 16);
          final strs = RegExp(r'<([0-9a-fA-F]+)>')
              .allMatches(arrayParts.group(3)!)
              .map((m) => _hexToUnicode(m.group(1)!))
              .toList();
          for (int i = 0; i < strs.length; i++) {
            result[lo + i] = strs[i];
          }
          continue;
        }
        // Simple range: <srcCodeLo> <srcCodeHi> <dstCodeLo>
        final rangeParts = RegExp(
          r'^<([0-9a-fA-F]+)>\s+<([0-9a-fA-F]+)>\s+<([0-9a-fA-F]+)>\s*$',
        ).firstMatch(trimmed);
        if (rangeParts != null) {
          final lo = int.parse(rangeParts.group(1)!, radix: 16);
          final hi = int.parse(rangeParts.group(2)!, radix: 16);
          var dst = int.parse(rangeParts.group(3)!, radix: 16);
          for (int code = lo; code <= hi; code++) {
            result[code] = String.fromCharCode(dst);
            dst++;
          }
        }
      }
    }

    return result;
  }

  /// Convert hex string to Unicode string.
  String _hexToUnicode(String hex) {
    if (hex.length <= 4) {
      return String.fromCharCode(int.parse(hex, radix: 16));
    }
    // Multi-char: interpret as sequence of UTF-16 code units
    final buffer = StringBuffer();
    for (int i = 0; i < hex.length - 3; i += 4) {
      buffer.writeCharCode(int.parse(hex.substring(i, i + 4), radix: 16));
    }
    return buffer.toString();
  }

  /// Decode a PDF string using font's ToUnicode map if available.
  String _decodeTextWithFont(
    String raw,
    String fontName,
    Map<String, Map<int, String>> fontUnicodeMaps,
    Map<String, bool> fontIsCID,
  ) {
    final unicodeMap = fontUnicodeMaps[fontName];
    final isCID = fontIsCID[fontName] == true;

    // For CID fonts with hex strings, decode as 2-byte codes
    if (isCID && raw.startsWith('<') && raw.endsWith('>')) {
      final hex =
          raw.substring(1, raw.length - 1).replaceAll(RegExp(r'\s'), '');
      final buffer = StringBuffer();
      // Each character is 2 bytes (4 hex digits)
      for (int i = 0; i + 3 < hex.length; i += 4) {
        final code = int.parse(hex.substring(i, i + 4), radix: 16);
        if (unicodeMap != null) {
          final mapped = unicodeMap[code];
          if (mapped != null) {
            buffer.write(mapped);
            continue;
          }
        }
        // Fallback: use code directly as Unicode code point
        if (code > 0) buffer.writeCharCode(code);
      }
      return buffer.toString();
    }

    // For non-CID fonts, use standard decoding
    final decoded = _decodePdfString(raw);
    if (unicodeMap == null || unicodeMap.isEmpty) return decoded;

    // Apply ToUnicode mapping for non-CID fonts
    final buffer = StringBuffer();
    for (int i = 0; i < decoded.length; i++) {
      final code = decoded.codeUnitAt(i);
      final mapped = unicodeMap[code];
      if (mapped != null) {
        buffer.write(mapped);
      } else {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  double _parseNum(String s) {
    return double.tryParse(s) ?? 0.0;
  }

  bool _isOperator(String token) {
    // Check if token is a PDF operator (alphabetic, not a number)
    if (token.isEmpty) return false;
    if (token.startsWith('/') ||
        token.startsWith('(') ||
        token.startsWith('<')) {
      return false;
    }
    return !RegExp(r'^-?[0-9.]+$').hasMatch(token);
  }

  String _decodePdfString(String raw) {
    if (raw.startsWith('(') && raw.endsWith(')')) {
      var s = raw.substring(1, raw.length - 1);
      // Unescape PDF string
      s = s
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\r', '\r')
          .replaceAll(r'\t', '\t')
          .replaceAll(r'\b', '\b')
          .replaceAll(r'\f', '\f')
          .replaceAll(r'\\', '\\')
          .replaceAll(r'\(', '(')
          .replaceAll(r'\)', ')');
      return s;
    }
    if (raw.startsWith('<') && raw.endsWith('>')) {
      // Hex string
      final hex =
          raw.substring(1, raw.length - 1).replaceAll(RegExp(r'\s'), '');
      final bytes = <int>[];
      for (int i = 0; i < hex.length - 1; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      // Check for BOM
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        // UTF-16BE
        final codeUnits = <int>[];
        for (int i = 2; i < bytes.length - 1; i += 2) {
          codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(codeUnits);
      }
      return String.fromCharCodes(bytes);
    }
    return raw;
  }
}

/// Simple PDF content stream tokenizer.
class _ContentTokenizer {
  final String content;
  int _pos = 0;
  final List<String> operands = [];
  List<dynamic>? lastArray;

  _ContentTokenizer(this.content);

  bool get hasMore => _pos < content.length;

  String? nextToken() {
    _skipWhitespace();
    if (!hasMore) return null;

    final ch = content[_pos];

    // String literal
    if (ch == '(') {
      final s = _readLiteralString();
      operands.add(s);
      return s;
    }

    // Hex string
    if (ch == '<' && _pos + 1 < content.length && content[_pos + 1] != '<') {
      final s = _readHexString();
      operands.add(s);
      return s;
    }

    // Dict
    if (ch == '<' && _pos + 1 < content.length && content[_pos + 1] == '<') {
      _skipDict();
      return nextToken();
    }

    // Array
    if (ch == '[') {
      lastArray = _readArray();
      return nextToken();
    }

    // Name
    if (ch == '/') {
      final name = _readName();
      operands.add(name);
      return name;
    }

    // Comment
    if (ch == '%') {
      _skipComment();
      return nextToken();
    }

    // Number or operator
    final word = _readWord();
    if (word.isEmpty) return nextToken();

    if (RegExp(r'^-?[0-9.]+$').hasMatch(word)) {
      operands.add(word);
      return word;
    }

    // It's an operator
    return word;
  }

  void _skipWhitespace() {
    while (_pos < content.length) {
      final c = content.codeUnitAt(_pos);
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0x0C ||
          c == 0x00) {
        _pos++;
      } else {
        break;
      }
    }
  }

  void _skipComment() {
    while (_pos < content.length &&
        content[_pos] != '\n' &&
        content[_pos] != '\r') {
      _pos++;
    }
  }

  String _readLiteralString() {
    final start = _pos;
    _pos++; // skip (
    int depth = 1;
    bool escape = false;

    while (_pos < content.length && depth > 0) {
      if (escape) {
        escape = false;
        _pos++;
        continue;
      }
      if (content[_pos] == '\\') {
        escape = true;
        _pos++;
        continue;
      }
      if (content[_pos] == '(') depth++;
      if (content[_pos] == ')') depth--;
      if (depth > 0) _pos++;
    }
    if (_pos < content.length) _pos++; // skip closing )
    return content.substring(start, _pos);
  }

  String _readHexString() {
    final start = _pos;
    _pos++; // skip <
    while (_pos < content.length && content[_pos] != '>') {
      _pos++;
    }
    if (_pos < content.length) _pos++; // skip >
    return content.substring(start, _pos);
  }

  void _skipDict() {
    _pos += 2; // skip <<
    int depth = 1;
    while (_pos < content.length && depth > 0) {
      if (_pos + 1 < content.length) {
        if (content[_pos] == '<' && content[_pos + 1] == '<') {
          depth++;
          _pos += 2;
          continue;
        }
        if (content[_pos] == '>' && content[_pos + 1] == '>') {
          depth--;
          _pos += 2;
          continue;
        }
      }
      _pos++;
    }
  }

  List<dynamic> _readArray() {
    _pos++; // skip [
    final items = <dynamic>[];
    _skipWhitespace();

    while (_pos < content.length && content[_pos] != ']') {
      _skipWhitespace();
      if (_pos >= content.length || content[_pos] == ']') break;

      if (content[_pos] == '(') {
        items.add(_readLiteralString());
      } else if (content[_pos] == '<') {
        items.add(_readHexString());
      } else {
        final word = _readWord();
        if (word.isNotEmpty) {
          final num = double.tryParse(word);
          if (num != null) {
            items.add(num);
          } else {
            items.add(word);
          }
        }
      }
      _skipWhitespace();
    }

    if (_pos < content.length) _pos++; // skip ]
    return items;
  }

  String _readName() {
    final start = _pos;
    _pos++; // skip /
    while (_pos < content.length) {
      final c = content.codeUnitAt(_pos);
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0x0C ||
          c == 0x00 ||
          c == 0x2F /* / */ ||
          c == 0x28 /* ( */ ||
          c == 0x29 /* ) */ ||
          c == 0x3C /* < */ ||
          c == 0x3E /* > */ ||
          c == 0x5B /* [ */ ||
          c == 0x5D /* ] */ ||
          c == 0x7B /* { */ ||
          c == 0x7D /* } */) {
        break;
      }
      _pos++;
    }
    return content.substring(start, _pos);
  }

  String _readWord() {
    _skipWhitespace();
    final start = _pos;
    while (_pos < content.length) {
      final c = content.codeUnitAt(_pos);
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0x0C ||
          c == 0x00 ||
          c == 0x2F /* / */ ||
          c == 0x28 /* ( */ ||
          c == 0x29 /* ) */ ||
          c == 0x3C /* < */ ||
          c == 0x3E /* > */ ||
          c == 0x5B /* [ */ ||
          c == 0x5D /* ] */) {
        break;
      }
      _pos++;
    }
    return content.substring(start, _pos);
  }
}
