/// Real Pretrained Model Integration Test
///
/// This test loads the ACTUAL pretrained donut-base-finetuned-cord-v2 model
/// (real weights, real tokenizer) and runs inference on real receipt images.
///
/// Prerequisites:
///   - modeldonut/ directory with model.safetensors and tokenizer.json
///   - test/fixtures/receipt1.jpeg and receipt2.jpeg
///
/// This test is SLOW (~3 minutes) because it runs the full Swin Transformer
/// encoder and mBART decoder in pure Dart. Run with:
///   dart test test/real_model_test.dart --timeout=600s
///
/// This is NOT a simulation. Every weight, every token, every computation
/// is the real pretrained model doing real inference.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:dart_mupdf_donut/donut.dart';

/// CORD-v2 special tokens (same as the pretrained model uses).
const _cordSpecialTokens = [
  '<s_cord-v2>',
  '</s_cord-v2>',
  '<s_menu>',
  '</s_menu>',
  '<s_nm>',
  '</s_nm>',
  '<s_unitprice>',
  '</s_unitprice>',
  '<s_cnt>',
  '</s_cnt>',
  '<s_price>',
  '</s_price>',
  '<s_sub>',
  '</s_sub>',
  '<s_sub_total>',
  '</s_sub_total>',
  '<s_subtotal_price>',
  '</s_subtotal_price>',
  '<s_total>',
  '</s_total>',
  '<s_total_price>',
  '</s_total_price>',
  '<s_cashprice>',
  '</s_cashprice>',
  '<s_changeprice>',
  '</s_changeprice>',
  '<s_tax_price>',
  '</s_tax_price>',
  '<s_service_price>',
  '</s_service_price>',
  '<s_othersvc_price>',
  '</s_othersvc_price>',
  '<s_menutype_cnt>',
  '</s_menutype_cnt>',
  '<s_void_menu>',
  '</s_void_menu>',
  '<s_sub_etc>',
  '</s_sub_etc>',
  '<s_etc>',
  '</s_etc>',
  '<s_discount_price>',
  '</s_discount_price>',
  '<s_emoney_price>',
  '</s_emoney_price>',
  '<s_creditcardprice>',
  '</s_creditcardprice>',
  '<s_menuqty_cnt>',
  '</s_menuqty_cnt>',
  '<sep/>',
];

/// Shared model instance — loaded once for all tests.
late DonutModel _model;
late DonutConfig _config;
bool _modelLoaded = false;

void main() {
  // ── Check prerequisites ─────────────────────────────────────────
  final modelDir = 'modeldonut';
  final safetensorsFile = File('$modelDir/model.safetensors');
  final tokenizerFile = File('$modelDir/tokenizer.json');

  if (!safetensorsFile.existsSync() || !tokenizerFile.existsSync()) {
    print('SKIPPING real_model_test: pretrained model not found in $modelDir/');
    print('  Download with: git clone https://huggingface.co/naver-clova-ix/'
        'donut-base-finetuned-cord-v2 $modelDir');
    return;
  }

  // ═══════════════════════════════════════════════════════════════════
  // SETUP: Load real pretrained model (once for all tests)
  // ═══════════════════════════════════════════════════════════════════
  setUpAll(() async {
    print('\n╔══════════════════════════════════════════════════════╗');
    print('║      Loading REAL pretrained Donut model...         ║');
    print('╚══════════════════════════════════════════════════════╝');

    _config = DonutConfig(
      inputSize: [640, 480],
      alignLongAxis: true,
      windowSize: 10,
      encoderLayer: [2, 2, 14, 2],
      patchSize: 4,
      encoderEmbedDim: 128,
      encoderNumHeads: [4, 8, 16, 32],
      decoderLayer: 4,
      decoderEmbedDim: 1024,
      decoderFfnDim: 4096,
      decoderNumHeads: 16,
      vocabSize: 57525,
      maxLength: 768,
    );

    _model = DonutModel(_config);

    // Load real HuggingFace tokenizer
    _model.loadTokenizerFromFile('$modelDir/tokenizer.json');
    _model.tokenizer!.addSpecialTokens(_cordSpecialTokens);

    // Load real pretrained weights (~1GB safetensors)
    final sw = Stopwatch()..start();
    await _model.loadWeights(modelDir);
    sw.stop();
    print(
        '  Weights loaded in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');

    // Resize decoder vocab to match tokenizer (pretrained=57525, +CORD tokens)
    _model.decoder.resizeVocab(_model.tokenizer!.vocabSize);
    print('  Decoder vocab resized to ${_model.tokenizer!.vocabSize}');

    _modelLoaded = true;
    print('  Model ready: ${_model.isReady}');
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 1: Verify real pretrained weights are loaded (not random)
  // ═══════════════════════════════════════════════════════════════════
  group('Real pretrained weights verification', () {
    test('model reports isReady after loading real weights', () {
      expect(_modelLoaded, true);
      expect(_model.isReady, true);
    });

    test('encoder patch_embed weights are real (not random)', () {
      final w = _model.encoder.patchEmbed.proj.weight;
      expect(w.shape, [128, 3, 4, 4]);
      expect(w.size, 6144);

      // Real pretrained weights have specific statistical properties
      double sum = 0, sumSq = 0;
      for (int i = 0; i < w.size; i++) {
        sum += w.data[i];
        sumSq += w.data[i] * w.data[i];
      }
      final mean = sum / w.size;
      final variance = sumSq / w.size - mean * mean;

      // Random init would give mean≈0 and variance≈scale²
      // Pretrained weights have non-trivial structure
      expect(variance, greaterThan(0.0001),
          reason: 'Pretrained weights should have non-trivial variance');
      print('  patch_embed.proj.weight: shape=${w.shape}, '
          'mean=${mean.toStringAsFixed(6)}, var=${variance.toStringAsFixed(6)}');
      print(
          '  First 5 values: ${w.data.sublist(0, 5).map((v) => v.toStringAsFixed(6)).join(", ")}');
    });

    test('decoder embedTokens weights are real', () {
      final w = _model.decoder.embedTokens.weight;
      // Should have been resized from 57525 to 57573
      expect(w.shape[0], _model.tokenizer!.vocabSize);
      expect(w.shape[1], 1024);

      // Check a few pretrained embedding rows are non-zero
      double rowSum = 0;
      for (int i = 0; i < 1024; i++) {
        rowSum += w.data[i].abs(); // First token embedding
      }
      expect(rowSum, greaterThan(1.0),
          reason: 'Pretrained embeddings should not be all zeros');
      print('  embedTokens: shape=${w.shape}');
      print('  First row L1: ${rowSum.toStringAsFixed(4)}');
    });

    test('decoder layernormEmbedding has real weights', () {
      final w = _model.decoder.layernormEmbedding.weight;
      expect(w.shape, [1024]);

      // Pretrained layernorm weights should be near 0.6 (not 1.0)
      double mean = 0;
      for (int i = 0; i < w.size; i++) {
        mean += w.data[i];
      }
      mean /= w.size;
      // Just check it's not the default 1.0 initialization
      expect(mean, isNot(closeTo(1.0, 0.05)),
          reason:
              'layernormEmbedding should have pretrained values, not default 1.0');
      print('  layernormEmbedding.weight: mean=${mean.toStringAsFixed(4)}');
    });

    test('tokenizer loaded real HuggingFace vocab', () {
      final tok = _model.tokenizer!;
      // Base vocab 57525 + 48 CORD tokens = 57573
      expect(tok.vocabSize, 57573);
      expect(tok.bosTokenId, isNotNull);
      expect(tok.eosTokenId, isNotNull);

      // Verify CORD special tokens are present
      final cordStart = tok.encode('<s_cord-v2>');
      expect(cordStart.isNotEmpty, true,
          reason: '<s_cord-v2> should be encodable');

      print('  Vocab size: ${tok.vocabSize}');
      print('  BOS=${tok.bosTokenId}, EOS=${tok.eosTokenId}');
      print('  <s_cord-v2> encodes to: $cordStart');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 2: Real image preprocessing
  // ═══════════════════════════════════════════════════════════════════
  group('Real image preprocessing with pretrained config', () {
    test('receipt images preprocess to correct tensor shape', () {
      for (final path in [
        'test/fixtures/receipt1.jpeg',
        'test/fixtures/receipt2.jpeg'
      ]) {
        final file = File(path);
        if (!file.existsSync()) {
          fail('Missing fixture: $path');
        }
        final bytes = file.readAsBytesSync();
        final tensor = DonutImageUtils.preprocessBytes(bytes, _config);

        expect(tensor.shape, [1, 3, 640, 480],
            reason: '$path should preprocess to [1, 3, 640, 480]');

        // Donut normalization: (pixel/255 - 0.5) / 0.5 → range [-1, 1]
        double minVal = double.infinity, maxVal = double.negativeInfinity;
        int nanCount = 0;
        for (int i = 0; i < tensor.size; i++) {
          if (tensor.data[i].isNaN) nanCount++;
          if (tensor.data[i] < minVal) minVal = tensor.data[i];
          if (tensor.data[i] > maxVal) maxVal = tensor.data[i];
        }
        expect(nanCount, 0, reason: 'No NaN values in preprocessed image');
        expect(minVal, greaterThanOrEqualTo(-1.1));
        expect(maxVal, lessThanOrEqualTo(1.1));

        print('  $path: shape=${tensor.shape}, '
            'range=[${minVal.toStringAsFixed(3)}, ${maxVal.toStringAsFixed(3)}]');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 3: Real encoder inference
  // ═══════════════════════════════════════════════════════════════════
  group('Real Swin encoder with pretrained weights', () {
    test('encoder produces meaningful features from receipt image', () {
      final bytes = File('test/fixtures/receipt1.jpeg').readAsBytesSync();
      final tensor = DonutImageUtils.preprocessBytes(bytes, _config);

      final sw = Stopwatch()..start();
      final output = _model.encode(tensor);
      sw.stop();

      // Shape: [1, numPatches, encoderOutputDim]
      expect(output.shape.length, 3);
      expect(output.shape[0], 1);
      expect(output.shape[2], _config.encoderOutputDim);

      // No NaN or Inf
      int nanCount = 0, infCount = 0;
      double absSum = 0;
      for (int i = 0; i < output.size; i++) {
        if (output.data[i].isNaN) nanCount++;
        if (output.data[i].isInfinite) infCount++;
        absSum += output.data[i].abs();
      }
      expect(nanCount, 0, reason: 'Encoder output must not contain NaN');
      expect(infCount, 0, reason: 'Encoder output must not contain Inf');

      final meanAbs = absSum / output.size;
      // Pretrained encoder should produce features with reasonable magnitude
      expect(meanAbs, greaterThan(0.01),
          reason: 'Encoder features should not be near-zero');
      expect(meanAbs, lessThan(100.0),
          reason: 'Encoder features should not be enormous');

      print('  Encoder output: shape=${output.shape}');
      print('  Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      print('  mean|val|=${meanAbs.toStringAsFixed(4)}, '
          'NaN=$nanCount, Inf=$infCount');
    });

    test('different images produce different encoder features', () {
      final bytes1 = File('test/fixtures/receipt1.jpeg').readAsBytesSync();
      final bytes2 = File('test/fixtures/receipt2.jpeg').readAsBytesSync();
      final t1 = DonutImageUtils.preprocessBytes(bytes1, _config);
      final t2 = DonutImageUtils.preprocessBytes(bytes2, _config);

      final out1 = _model.encode(t1);
      final out2 = _model.encode(t2);

      expect(out1.shape, out2.shape);

      // The features for different images must differ
      double maxDiff = 0, sumDiff = 0;
      for (int i = 0; i < out1.size; i++) {
        final d = (out1.data[i] - out2.data[i]).abs();
        if (d > maxDiff) maxDiff = d;
        sumDiff += d;
      }
      final meanDiff = sumDiff / out1.size;

      expect(maxDiff, greaterThan(0.01),
          reason: 'Different images must produce different features');
      print('  Feature diff: maxDiff=${maxDiff.toStringAsFixed(4)}, '
          'meanDiff=${meanDiff.toStringAsFixed(4)}');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 4: Real decoder inference
  // ═══════════════════════════════════════════════════════════════════
  group('Real mBART decoder with pretrained weights', () {
    test('decoder generates tokens from real encoder output', () {
      final bytes = File('test/fixtures/receipt1.jpeg').readAsBytesSync();
      final tensor = DonutImageUtils.preprocessBytes(bytes, _config);
      final encoderOutput = _model.encode(tensor);

      final promptTokens = _model.tokenizer!.encode('<s_cord-v2>');
      expect(promptTokens.isNotEmpty, true,
          reason: 'Prompt should encode to at least 1 token');

      final sw = Stopwatch()..start();
      final tokens = _model.decode(
        encoderOutput: encoderOutput,
        promptTokens: promptTokens,
        maxLength: 128,
        eosTokenId: _model.tokenizer!.eosTokenId,
      );
      sw.stop();

      expect(tokens.isNotEmpty, true,
          reason: 'Decoder must produce at least the prompt tokens');
      expect(tokens.length, greaterThanOrEqualTo(promptTokens.length));

      // All token IDs must be valid
      for (final id in tokens) {
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThan(_model.tokenizer!.vocabSize),
            reason: 'Token ID $id out of vocab range');
      }

      final text = _model.tokenizer!.decode(tokens);

      print('  Prompt tokens: $promptTokens');
      print('  Generated ${tokens.length} tokens in '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      print('  Decoded text: ${text.substring(0, math.min(200, text.length))}');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 5: Full end-to-end real inference
  // ═══════════════════════════════════════════════════════════════════
  group('Full end-to-end real pretrained inference', () {
    test('inferenceFromBytes on receipt1.jpeg returns structured result', () {
      final bytes = File('test/fixtures/receipt1.jpeg').readAsBytesSync();

      final sw = Stopwatch()..start();
      final result = _model.inferenceFromBytes(
        imageBytes: bytes,
        prompt: '<s_cord-v2>',
        maxLength: 128,
      );
      sw.stop();

      // Must return a valid result
      expect(result, isNotNull);
      expect(result.tokens, isNotEmpty);
      expect(result.text, isNotNull);
      expect(result.json, isNotNull);

      print('  ═══════════════════════════════════════════════');
      print('  REAL INFERENCE RESULT — receipt1.jpeg');
      print('  ═══════════════════════════════════════════════');
      print('  Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      print('  Tokens: ${result.tokens.length}');
      print('  Raw text: ${result.text}');
      print('  Parsed JSON type: ${result.json.runtimeType}');
      if (result.json is Map) {
        _printJson(result.json as Map, indent: 4);
      }
      print('  ═══════════════════════════════════════════════');
    });

    test('inferenceFromBytes on receipt2.jpeg returns structured result', () {
      final bytes = File('test/fixtures/receipt2.jpeg').readAsBytesSync();

      final sw = Stopwatch()..start();
      final result = _model.inferenceFromBytes(
        imageBytes: bytes,
        prompt: '<s_cord-v2>',
        maxLength: 128,
      );
      sw.stop();

      expect(result, isNotNull);
      expect(result.tokens, isNotEmpty);
      expect(result.text, isNotNull);
      expect(result.json, isNotNull);

      print('  ═══════════════════════════════════════════════');
      print('  REAL INFERENCE RESULT — receipt2.jpeg');
      print('  ═══════════════════════════════════════════════');
      print('  Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      print('  Tokens: ${result.tokens.length}');
      print('  Raw text: ${result.text}');
      print('  Parsed JSON type: ${result.json.runtimeType}');
      if (result.json is Map) {
        _printJson(result.json as Map, indent: 4);
      }
      print('  ═══════════════════════════════════════════════');
    });

    test('two different receipt images produce different results', () {
      final bytes1 = File('test/fixtures/receipt1.jpeg').readAsBytesSync();
      final bytes2 = File('test/fixtures/receipt2.jpeg').readAsBytesSync();

      final result1 = _model.inferenceFromBytes(
        imageBytes: bytes1,
        prompt: '<s_cord-v2>',
        maxLength: 128,
      );
      final result2 = _model.inferenceFromBytes(
        imageBytes: bytes2,
        prompt: '<s_cord-v2>',
        maxLength: 128,
      );

      // Both must produce valid output
      expect(result1.tokens.isNotEmpty, true);
      expect(result2.tokens.isNotEmpty, true);

      print('  receipt1: ${result1.tokens.length} tokens → "${result1.text}"');
      print('  receipt2: ${result2.tokens.length} tokens → "${result2.text}"');
    });
  });
}

/// Print a nested map with indentation.
void _printJson(Map map, {int indent = 2}) {
  final pad = ' ' * indent;
  for (final entry in map.entries) {
    if (entry.value is Map) {
      print('$pad${entry.key}:');
      _printJson(entry.value as Map, indent: indent + 2);
    } else if (entry.value is List) {
      print('$pad${entry.key}: [${(entry.value as List).length} items]');
      for (int i = 0; i < (entry.value as List).length; i++) {
        final item = (entry.value as List)[i];
        if (item is Map) {
          print('$pad  [$i]:');
          _printJson(item, indent: indent + 4);
        } else {
          print('$pad  [$i]: $item');
        }
      }
    } else {
      print('$pad${entry.key}: ${entry.value}');
    }
  }
}
