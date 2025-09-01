// @dart=3.6
// ignore_for_file: directives_ordering
// build_runner >=2.4.16
// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:build_runner_core/build_runner_core.dart' as _i1;
import 'package:build_web_compilers/builders.dart' as _i2;
import 'package:build_modules/builders.dart' as _i3;
import 'package:build_config/build_config.dart' as _i4;
import 'package:build/build.dart' as _i5;
import 'dart:isolate' as _i6;
import 'package:build_runner/src/build_script_generate/build_process_state.dart'
    as _i7;
import 'package:build_runner/build_runner.dart' as _i8;
import 'dart:io' as _i9;

final _builders = <_i1.BuilderApplication>[
  _i1.apply(
    r'build_web_compilers:sdk_js',
    [
      _i2.sdkJsCompile,
      _i2.sdkJsCopyRequirejs,
    ],
    _i1.toNoneByDefault(),
    isOptional: true,
    hideOutput: true,
  ),
  _i1.apply(
    r'build_modules:module_library',
    [_i3.moduleLibraryBuilder],
    _i1.toAllPackages(),
    isOptional: true,
    hideOutput: true,
    appliesBuilders: const [r'build_modules:module_cleanup'],
  ),
  _i1.apply(
    r'build_web_compilers:ddc_modules',
    [
      _i2.ddcMetaModuleBuilder,
      _i2.ddcMetaModuleCleanBuilder,
      _i2.ddcModuleBuilder,
    ],
    _i1.toNoneByDefault(),
    isOptional: true,
    hideOutput: true,
    appliesBuilders: const [r'build_modules:module_cleanup'],
  ),
  _i1.apply(
    r'build_web_compilers:ddc',
    [
      _i2.ddcKernelBuilder,
      _i2.ddcBuilder,
    ],
    _i1.toAllPackages(),
    isOptional: true,
    hideOutput: true,
    appliesBuilders: const [
      r'build_web_compilers:ddc_modules',
      r'build_web_compilers:dart2js_modules',
      r'build_web_compilers:dart2wasm_modules',
      r'build_web_compilers:dart_source_cleanup',
    ],
  ),
  _i1.apply(
    r'build_web_compilers:dart2wasm_modules',
    [
      _i2.dart2wasmMetaModuleBuilder,
      _i2.dart2wasmMetaModuleCleanBuilder,
      _i2.dart2wasmModuleBuilder,
    ],
    _i1.toNoneByDefault(),
    isOptional: true,
    hideOutput: true,
    appliesBuilders: const [r'build_modules:module_cleanup'],
  ),
  _i1.apply(
    r'build_web_compilers:dart2js_modules',
    [
      _i2.dart2jsMetaModuleBuilder,
      _i2.dart2jsMetaModuleCleanBuilder,
      _i2.dart2jsModuleBuilder,
    ],
    _i1.toNoneByDefault(),
    isOptional: true,
    hideOutput: true,
    appliesBuilders: const [r'build_modules:module_cleanup'],
  ),
  _i1.apply(
    r'build_web_compilers:entrypoint',
    [_i2.webEntrypointBuilder],
    _i1.toRoot(),
    hideOutput: true,
    defaultGenerateFor: const _i4.InputSet(
      include: [
        r'web/**',
        r'test/**.dart.browser_test.dart',
        r'example/**',
        r'benchmark/**',
      ],
      exclude: [
        r'test/**.node_test.dart',
        r'test/**.vm_test.dart',
      ],
    ),
    defaultOptions: const _i5.BuilderOptions(<String, dynamic>{
      r'dart2js_args': <dynamic>[r'--minify']
    }),
    defaultDevOptions: const _i5.BuilderOptions(<String, dynamic>{
      r'dart2wasm_args': <dynamic>[r'--enable-asserts'],
      r'dart2js_args': <dynamic>[r'--enable-asserts'],
    }),
    defaultReleaseOptions:
        const _i5.BuilderOptions(<String, dynamic>{r'compiler': r'dart2js'}),
    appliesBuilders: const [r'build_web_compilers:dart2js_archive_extractor'],
  ),
  _i1.applyPostProcess(
    r'build_modules:module_cleanup',
    _i3.moduleCleanup,
  ),
  _i1.applyPostProcess(
    r'build_web_compilers:dart2js_archive_extractor',
    _i2.dart2jsArchiveExtractor,
    defaultReleaseOptions:
        const _i5.BuilderOptions(<String, dynamic>{r'filter_outputs': true}),
  ),
  _i1.applyPostProcess(
    r'build_web_compilers:dart_source_cleanup',
    _i2.dartSourceCleanup,
    defaultReleaseOptions:
        const _i5.BuilderOptions(<String, dynamic>{r'enabled': true}),
  ),
];
void main(
  List<String> args, [
  _i6.SendPort? sendPort,
]) async {
  await _i7.buildProcessState.receive(sendPort);
  _i7.buildProcessState.isolateExitCode = await _i8.run(
    args,
    _builders,
  );
  _i9.exitCode = _i7.buildProcessState.isolateExitCode!;
  await _i7.buildProcessState.send(sendPort);
}
