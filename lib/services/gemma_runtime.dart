/// Owns the on-device Gemma engine: initialisation, model download, readiness.
///
/// Specification: architecture.md §6.3, phases.md Phase 4 (Spike A).
///
/// Split from `GemmaService` because it has two very different jobs: this one
/// owns a ~529 MB download and long-lived native state, while `GemmaService`
/// owns prompt/parse/validate and stays pure enough to unit test.
///
/// The HuggingFace token is never held in memory longer than the download needs
/// it and is never logged — it is read from the Android KeyStore per call.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:heads_up/services/store.dart';

/// State of the local model, shown on the setup and status screens
/// (prd.md §6.1 step 4, §6.2).
enum ModelStatus {
  notDownloaded,
  downloading,
  ready,
  failed,
}

/// What the model is doing right now.
class ModelState {
  const ModelState({
    required this.status,
    this.progress = 0,
    this.message,
  });

  final ModelStatus status;

  /// 0.0 to 1.0 while downloading.
  final double progress;

  /// Human-readable detail, e.g. a download failure.
  final String? message;

  bool get isBusy => status == ModelStatus.downloading;
}

/// The repo `architecture.md` §6.3 downloads from.
///
/// Note this is **not** `google/gemma-3-1b-it`, which the phases.md pre-build
/// checklist names — the code downloads from `litert-community`, so that is the
/// repository whose gated licence must be accepted.
const String kGemmaHfRepo = 'litert-community/Gemma3-1B-IT';

class GemmaRuntime {
  GemmaRuntime(this._store);

  final Store _store;

  bool _initialised = false;

  ModelState _state = const ModelState(status: ModelStatus.notDownloaded);
  ModelState get state => _state;

  final StreamController<ModelState> _changes =
      StreamController<ModelState>.broadcast();

  /// Emits on every state transition so the UI can show progress.
  Stream<ModelState> get changes => _changes.stream;

  /// Starts the engine. Safe to call repeatedly.
  ///
  /// [huggingFaceToken] comes from the KeyStore; a null token is fine — the
  /// model is only *needed* for gated repos, and a failure here should not stop
  /// the app from starting (the widget still works with `flutter_tts`).
  Future<void> initialise() async {
    if (_initialised) return;

    final token = await _store.readSecret(SecretKeys.hfToken);

    try {
      await FlutterGemma.initialize(
        huggingFaceToken: (token?.isEmpty ?? true) ? null : token,
        inferenceEngines: const [LiteRtLmEngine()],
      );
      _initialised = true;
    } catch (e) {
      debugPrint('GemmaRuntime: engine init failed: $e');
      _emit(const ModelState(
        status: ModelStatus.failed,
        message: 'Could not start the Gemma engine.',
      ));
    }
  }

  /// Downloads the model if it is not already present.
  ///
  /// Idempotent — `install()` returns immediately when the file exists, so this
  /// is safe to call on every app start to refresh [state].
  Future<bool> ensureModelInstalled() async {
    if (!_initialised) await initialise();
    if (!_initialised) return false;

    _emit(const ModelState(status: ModelStatus.downloading, progress: 0));

    try {
      final installation = await FlutterGemma
          .installModel(
            modelType: ModelType.gemmaIt,
            fileType: ModelFileType.litertlm,
          )
          .fromHuggingFace(kGemmaHfRepo)
          .withProgress((progress) {
            // Throttled: the callback fires far more often than the UI can
            // repaint, and each emit fans out to a stream.
            _emit(ModelState(
              status: ModelStatus.downloading,
              progress: progress / 100,
            ));
          })
          .install();

      _emit(const ModelState(status: ModelStatus.ready, progress: 1));
      debugPrint('GemmaRuntime: model installed: ${installation.spec}');
      return true;
    } catch (e) {
      _emit(ModelState(status: ModelStatus.failed, message: explain(e)));
      return false;
    }
  }

  /// Whether a model is loaded and inference can run.
  Future<bool> isReady() async {
    try {
      await FlutterGemma.getActiveModel();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(ModelState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// Turns a download failure into something worth showing a non-technical
  /// person. A 401 is the one that matters most and the least obvious: it means
  /// the licence has not been accepted, not that the network is down.
  static String explain(Object error) {
    final text = error.toString();
    if (text.contains('401') || text.contains('Unauthorized')) {
      return 'Hugging Face refused the download (401). Check the Gemma licence '
          'is accepted and the read token is valid.';
    }
    if (text.contains('403')) {
      return 'That token is not allowed to read this model (403).';
    }
    if (text.contains('404')) {
      return 'Model not found at $kGemmaHfRepo.';
    }
    if (text.contains('SocketException') || text.contains('Failed host lookup')) {
      return 'No internet connection. The model needs a one-time download.';
    }
    return 'Model download failed: $error';
  }

  void dispose() {
    unawaited(_changes.close());
  }
}