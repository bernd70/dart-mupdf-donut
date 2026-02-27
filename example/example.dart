// ignore_for_file: avoid_print
/// Real Donut Receipt Extraction Example
///
/// This example loads the pretrained donut-base-finetuned-cord-v2 model
/// and extracts structured data from a receipt image — no faking.
///
/// Prerequisites:
///   1. Download model:
///      git clone https://huggingface.co/naver-clova-ix/donut-base-finetuned-cord-v2 modeldonut
///   2. Convert weights (requires Python with torch + safetensors):
///      python3 tools/convert_weights.py modeldonut
///   3. Place a receipt image (JPEG/PNG) at the path you pass as argument,
///      or use the included test fixture.
///
/// Run:
///   dart run example/example.dart [receipt_image_path]
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_mupdf_donut/donut.dart';

/// CORD-v2 special tokens used by the receipt extraction model.
const cordSpecialTokens = [
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

Future<void> main(List<String> args) async {
  final modelDir = 'modeldonut';

  // Determine image path
  final imagePath = args.isNotEmpty
      ? args[0]
      : 'test/fixtures/receipt1.jpeg'; // default to test fixture

  // ── Validate prerequisites ──────────────────────────────────────────
  final safetensorsFile = File('$modelDir/model.safetensors');
  final tokenizerFile = File('$modelDir/tokenizer.json');
  final imageFile = File(imagePath);

  if (!safetensorsFile.existsSync()) {
    print('ERROR: model.safetensors not found in $modelDir/');
    print('');
    print('Setup instructions:');
    print('  1. git clone https://huggingface.co/naver-clova-ix/'
        'donut-base-finetuned-cord-v2 $modelDir');
    print('  2. python3 tools/convert_weights.py $modelDir');
    exit(1);
  }
  if (!tokenizerFile.existsSync()) {
    print('ERROR: tokenizer.json not found in $modelDir/');
    exit(1);
  }
  if (!imageFile.existsSync()) {
    print('ERROR: Image not found: $imagePath');
    print('  Pass a receipt image path as argument, or place one at '
        'test/fixtures/receipt1.jpeg');
    exit(1);
  }

  print('╔══════════════════════════════════════════════════════╗');
  print('║  Donut Receipt Extraction — Real Pretrained Model   ║');
  print('╚══════════════════════════════════════════════════════╝');
  print('');

  // ── Step 1: Create model ──────────────────────────────────────────
  // Use a reduced input size for feasible pure-Dart inference.
  // The pretrained weights still work — Swin Transformer handles variable
  // spatial sizes. Lower resolution = faster but less accurate.
  // Full base config uses [2560, 1920] but that would take hours in pure Dart.
  final config = DonutConfig(
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

  print('Step 1: Creating model');
  print('  Input size: ${config.inputSize[1]}x${config.inputSize[0]}');
  print('  Encoder: Swin-B [${config.encoderLayer.join(", ")}]');
  print('  Decoder: mBART ${config.decoderLayer} layers');
  final model = DonutModel(config);

  // ── Step 2: Load tokenizer ────────────────────────────────────────
  print('\nStep 2: Loading tokenizer');
  model.loadTokenizerFromFile('$modelDir/tokenizer.json');
  print('  Base vocab: ${model.tokenizer!.vocabSize} tokens');

  // Add CORD-v2 special tokens
  model.tokenizer!.addSpecialTokens(cordSpecialTokens);
  print('  With CORD tokens: ${model.tokenizer!.vocabSize} tokens');

  // ── Step 3: Load pretrained weights ───────────────────────────────
  print('\nStep 3: Loading pretrained weights');
  final sw = Stopwatch()..start();
  await model.loadWeights(modelDir);
  sw.stop();
  print(
      '  Weights loaded in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  print('  Model ready: ${model.isReady}');

  // Resize decoder vocab to accommodate CORD special tokens
  final newVocabSize = model.tokenizer!.vocabSize;
  model.decoder.resizeVocab(newVocabSize);
  print('  Decoder vocab resized to $newVocabSize');

  // Verify weights are real (not random)
  final patchW = model.encoder.patchEmbed.proj.weight;
  double weightSum = 0;
  for (int i = 0; i < math.min(100, patchW.size); i++) {
    weightSum += patchW.data[i].abs();
  }
  print('  Weight check: patch_embed avg|w|='
      '${(weightSum / math.min(100, patchW.size)).toStringAsFixed(4)}');

  // ── Step 4: Load and preprocess image ─────────────────────────────
  print('\nStep 4: Preprocessing image');
  print('  Source: $imagePath');
  final imageBytes = imageFile.readAsBytesSync();
  print('  File size: ${(imageBytes.length / 1024).toStringAsFixed(1)} KB');

  final sw2 = Stopwatch()..start();
  final imageTensor = DonutImageUtils.preprocessBytes(imageBytes, config);
  sw2.stop();
  print('  Tensor shape: ${imageTensor.shape}');
  print('  Preprocess time: ${sw2.elapsedMilliseconds}ms');

  // ── Step 5: Run inference ─────────────────────────────────────────
  print('\nStep 5: Running inference (this may take a while in pure Dart)');
  print('  Prompt: <s_cord-v2>');
  final sw3 = Stopwatch()..start();

  // Encode
  print('  Encoding image...');
  final encoderOutput = model.encode(imageTensor);
  final encodeTime = sw3.elapsedMilliseconds;
  print('  Encoder output: ${encoderOutput.shape}');
  print('  Encode time: ${(encodeTime / 1000).toStringAsFixed(1)}s');

  // Check for NaN in encoder output
  int nanCount = 0;
  double absSum = 0;
  for (int i = 0; i < encoderOutput.size; i++) {
    if (encoderOutput.data[i].isNaN) nanCount++;
    absSum += encoderOutput.data[i].abs();
  }
  if (nanCount > 0) {
    print('  WARNING: $nanCount NaN values in encoder output');
  }
  print('  Encoder output mean|val|: '
      '${(absSum / encoderOutput.size).toStringAsFixed(4)}');

  // Decode
  print('  Decoding tokens...');
  final promptTokens = model.tokenizer!.encode('<s_cord-v2>');
  final tokens = model.decode(
    encoderOutput: encoderOutput,
    promptTokens: promptTokens,
    maxLength: 128,
    eosTokenId: model.tokenizer!.eosTokenId,
  );
  sw3.stop();
  final totalTime = sw3.elapsedMilliseconds;
  print(
      '  Decode time: ${((totalTime - encodeTime) / 1000).toStringAsFixed(1)}s');
  print('  Total time: ${(totalTime / 1000).toStringAsFixed(1)}s');
  print('  Generated ${tokens.length} tokens');

  // ── Step 6: Display results ───────────────────────────────────────
  final rawText = model.tokenizer!.decode(tokens);
  final parsedJson = DonutModel.token2json(rawText);

  print('\n${"═" * 56}');
  print('EXTRACTION RESULT');
  print('${"═" * 56}');
  print('Raw tokens: ${tokens.length} IDs');
  print('Raw text:');
  print('  $rawText');
  print('\nParsed JSON:');
  _prettyPrint(parsedJson);
  print('${"═" * 56}');
  print('');
  print('Note: This is a real inference using pretrained weights.');
  print('At reduced resolution (${config.inputSize[1]}x${config.inputSize[0]}) '
      'accuracy is lower.');
  print('For best results, use inputSize: [2560, 1920] (much slower).');
}

/// Pretty-print a nested JSON structure.
void _prettyPrint(dynamic obj, {int indent = 2}) {
  final pad = ' ' * indent;
  if (obj is Map) {
    for (final entry in obj.entries) {
      if (entry.value is Map || entry.value is List) {
        print('$pad${entry.key}:');
        _prettyPrint(entry.value, indent: indent + 2);
      } else {
        print('$pad${entry.key}: ${entry.value}');
      }
    }
  } else if (obj is List) {
    for (int i = 0; i < obj.length; i++) {
      if (obj[i] is Map || obj[i] is List) {
        print('$pad[$i]:');
        _prettyPrint(obj[i], indent: indent + 2);
      } else {
        print('$pad[$i]: ${obj[i]}');
      }
    }
  } else {
    print('$pad$obj');
  }
}
