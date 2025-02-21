import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:glob/glob.dart';
import 'package:mason_logger/mason_logger.dart' hide ExitCode;
import 'package:path/path.dart' as path;
import 'package:sip_cli/domain/any_arg_parser.dart';
import 'package:sip_cli/domain/find_file.dart';
import 'package:sip_cli/domain/run_many_scripts.dart';
import 'package:sip_cli/domain/run_one_script.dart';
import 'package:sip_cli/domain/testable.dart';
import 'package:sip_cli/utils/determine_flutter_or_dart.dart';
import 'package:sip_cli/utils/exit_code.dart';
import 'package:sip_cli/utils/exit_code_extensions.dart';
import 'package:sip_cli/utils/stopwatch_extensions.dart';
import 'package:sip_cli/utils/write_optimized_test_file.dart';
import 'package:sip_script_runner/sip_script_runner.dart';

part '__both_args.dart';
part '__dart_args.dart';
part '__flutter_args.dart';
part '__conflicting_args.dart';

abstract mixin class TesterMixin {
  const TesterMixin();

  static const String optimizedTestBasename = '.test_optimizer';
  static String optimizedTestFileName(String type) {
    if (type == 'dart' || type == 'flutter') {
      return '$optimizedTestBasename.dart';
    }

    return '$optimizedTestBasename.$type.dart';
  }

  Logger get logger;
  PubspecYaml get pubspecYaml;
  FindFile get findFile;
  PubspecLock get pubspecLock;
  FileSystem get fs;
  Bindings get bindings;

  ({
    List<String> both,
    List<String> dart,
    List<String> flutter,
  }) getArgs<T>(Command<T> command) {
    final bothArgs = command._getBothArgs();
    final dartArgs = command._getDartArgs();
    final flutterArgs = command._getFlutterArgs();

    return (both: bothArgs, dart: dartArgs, flutter: flutterArgs);
  }

  void addTestFlags<T>(Command<T> command) {
    command
      ..argParser.addSeparator(cyan.wrap('Dart Flags:')!)
      .._addDartArgs()
      ..argParser.addSeparator(cyan.wrap('Flutter Flags:')!)
      .._addFlutterArgs()
      ..argParser.addSeparator(cyan.wrap('Overlapping Flags:')!)
      .._addBothArgs()
      ..argParser.addSeparator(cyan.wrap('Conflicting Flags:')!)
      .._addConflictingArgs();
  }

  void warnDartOrFlutterTests({
    required bool isFlutterOnly,
    required bool isDartOnly,
  }) {
    if (isDartOnly || isFlutterOnly) {
      if (isDartOnly && !isFlutterOnly) {
        logger.info('Running only dart tests');
      } else if (isFlutterOnly && !isDartOnly) {
        logger.info('Running only flutter tests');
      } else {
        logger.info('Running both dart and flutter tests');
      }
    }
  }

  /// This method is used to find all the pubspecs in the project
  ///
  /// When [isRecursive] is true, this finds pubspecs in subdirectories
  /// as well as the current directory.
  ///
  /// When [isRecursive] is false, this only finds the pubspec in the
  /// current directory.
  Future<List<String>> pubspecs({
    required bool isRecursive,
  }) async {
    final pubspecs = <String>{};

    final pubspec = pubspecYaml.nearest();

    if (pubspec != null) {
      pubspecs.add(pubspec);
    }

    if (isRecursive) {
      logger.detail('Running tests recursively');
      final children = await pubspecYaml.children();
      pubspecs.addAll(children.map((e) => path.join(path.separator, e)));
    }

    return pubspecs.toList();
  }

  /// This method is used to get the test directories and the tools
  /// to run the tests
  ///
  /// It returns a map of test directories and the tools to run the tests
  (
    (
      List<String> testDirs,
      Map<String, DetermineFlutterOrDart> dirTools,
    )?,
    ExitCode? exitCode,
  ) getTestDirs(
    List<String> pubspecs, {
    required bool isFlutterOnly,
    required bool isDartOnly,
  }) {
    final testDirs = <String>[];
    final dirTools = <String, DetermineFlutterOrDart>{};

    logger.detail(
      'Found ${pubspecs.length} pubspecs, checking for test directories',
    );
    for (final pubspec in pubspecs) {
      final projectRoot = path.dirname(pubspec);
      final testDirectory = path.join(path.dirname(pubspec), 'test');

      if (!fs.directory(testDirectory).existsSync()) {
        logger
            .detail('No test directory found in ${path.relative(projectRoot)}');
        continue;
      }

      final tool = DetermineFlutterOrDart(
        pubspecYaml: path.join(projectRoot, 'pubspec.yaml'),
        findFile: findFile,
        pubspecLock: pubspecLock,
      );

      // we only care checking for flutter or
      // dart tests if we are not running both
      if (isFlutterOnly ^ isDartOnly) {
        if (tool.isFlutter && isDartOnly && !isFlutterOnly) {
          continue;
        }

        if (tool.isDart && isFlutterOnly) {
          continue;
        }
      }

      testDirs.add(testDirectory);
      dirTools[testDirectory] = tool;
    }

    if (testDirs.isEmpty) {
      var forTool = '';

      if (isFlutterOnly ^ isDartOnly) {
        forTool = ' ';
        forTool += isDartOnly ? 'dart' : 'flutter';
      }
      logger.err('No$forTool tests found');
      return (null, ExitCode.unavailable);
    }

    return ((testDirs, dirTools), null);
  }

  Map<String, DetermineFlutterOrDart> writeOptimizedFiles(
    List<String> testDirs,
    Map<String, DetermineFlutterOrDart> dirTools,
  ) {
    final optimizedFiles = <String, DetermineFlutterOrDart>{};

    for (final testDir in testDirs) {
      final tool = dirTools[testDir]!;
      final allFiles = Glob(path.join('**_test.dart'))
          .listFileSystemSync(fs, followLinks: false, root: testDir);

      /// the key is the name of the test type
      final testFiles = <String, List<String>>{};

      for (final file in allFiles) {
        if (file is! File) continue;

        var testType = 'dart';

        if (tool.isFlutter) {
          final content = file.readAsStringSync();

          final flutterTestType = RegExp(r'(\w+WidgetsFlutterBinding)')
              .firstMatch(content)
              ?.group(1)
              ?.replaceAll('TestWidgetsFlutterBinding', '')
              .toLowerCase();

          if (flutterTestType == null) {
            testType = 'flutter';
          } else {
            if (flutterTestType.isEmpty) {
              testType = 'test';
            } else {
              testType = flutterTestType;
            }

            logger.detail('Found Flutter $testType test');
          }
        }

        final fileName = path.basename(file.path);

        if (fileName.contains(optimizedTestBasename)) {
          continue;
        }

        (testFiles[testType] ??= []).add(file.path);
      }

      if (testFiles.isEmpty) {
        continue;
      }

      for (final MapEntry(key: type, value: testFiles) in testFiles.entries) {
        final optimizedPath = path.join(testDir, optimizedTestFileName(type));
        fs.file(optimizedPath).createSync(recursive: true);

        final testDirs = testFiles
            .map((e) => Testable(absolute: e, optimizedPath: optimizedPath));

        final content =
            writeOptimizedTestFile(testDirs, isFlutterPackage: tool.isFlutter);

        fs.file(optimizedPath).writeAsStringSync(content);

        optimizedFiles[optimizedPath] = tool;
      }
    }

    return optimizedFiles;
  }

  String packageRootFor(String filePath) {
    final parts = path.split(filePath);

    String root;
    if (parts.contains('test')) {
      root = parts.sublist(0, parts.indexOf('test')).join(path.separator);
    } else if (parts.contains('lib')) {
      root = parts.sublist(0, parts.indexOf('lib')).join(path.separator);
    } else {
      root = path.basename(path.dirname(filePath));
    }

    if (root.isEmpty) {
      root = '.';
    }

    return root;
  }

  List<CommandToRun> getCommandsToRun(
    Map<String, DetermineFlutterOrDart> testFiles, {
    required List<String> flutterArgs,
    required List<String> dartArgs,
  }) {
    final commandsToRun = <CommandToRun>[];

    for (final MapEntry(key: test, value: tool) in testFiles.entries) {
      final projectRoot = packageRootFor(test);

      final toolArgs = tool.isFlutter ? flutterArgs : dartArgs;

      final command = tool.tool();

      final testPath = path.relative(test, from: projectRoot);

      final script = '$command test $testPath ${toolArgs.join(' ')}';

      logger.detail('Test command: $script');

      var label = darkGray.wrap('Running (')!;
      label += cyan.wrap(command)!;
      label += darkGray.wrap(') tests in ')!;
      final dirName = packageRootFor(path.relative(test));

      label += darkGray.wrap(dirName)!;

      commandsToRun.add(
        CommandToRun(
          command: script,
          workingDirectory: projectRoot,
          keys: null,
          label: label,
        ),
      );
    }

    return commandsToRun;
  }

  Future<ExitCode> runCommands(
    List<CommandToRun> commandsToRun, {
    required bool runConcurrently,
    required bool bail,
  }) async {
    if (runConcurrently) {
      for (final command in commandsToRun) {
        logger.detail('Script: ${darkGray.wrap(command.command)}');
      }

      final runMany = RunManyScripts(
        commands: commandsToRun,
        bindings: bindings,
        logger: logger,
      );

      final exitCodes = await runMany.run(
        label: 'Running tests',
        bail: bail,
      );

      exitCodes.printErrors(commandsToRun, logger);

      return exitCodes.exitCode(logger);
    }

    ExitCode? exitCode;

    for (final command in commandsToRun) {
      logger.detail(command.command);
      final scriptRunner = RunOneScript(
        command: command,
        bindings: bindings,
        logger: logger,
        showOutput: true,
      );

      final stopwatch = Stopwatch()..start();

      logger.info(darkGray.wrap(command.label));

      final result = await scriptRunner.run();

      final time = (stopwatch..stop()).format();

      logger
        ..info('Finished in ${cyan.wrap(time)}')
        ..write('\n');

      if (result != ExitCode.success) {
        exitCode = result;

        if (bail) {
          return exitCode;
        }
      }
    }

    return exitCode ?? ExitCode.success;
  }

  void cleanUp(Iterable<String> optimizedFiles) {
    for (final optimizedFile in optimizedFiles) {
      if (!optimizedFile.contains(optimizedTestBasename)) continue;

      fs.file(optimizedFile).deleteSync();
    }
  }

  (Map<String, DetermineFlutterOrDart>? filesToTest, ExitCode? exitCode)
      getTests(
    List<String> testDirs,
    Map<String, DetermineFlutterOrDart> dirTools, {
    required bool optimize,
  }) {
    logger.detail(
      '${optimize ? '' : 'NOT '}Optimizing ${testDirs.length} test files',
    );

    if (optimize) {
      final done = logger.progress('Optimizing test files');
      final result = writeOptimizedFiles(testDirs, dirTools);

      done.complete();

      if (result.isEmpty) {
        logger.err('No tests found');
        return (null, ExitCode.unavailable);
      }

      return (result, null);
    }

    logger.warn('Running tests without optimization');

    final dirsWithTests = <String>[];

    for (final MapEntry(key: dir, value: _) in dirTools.entries) {
      final result = Glob('**_test.dart')
          .listFileSystemSync(fs, followLinks: false, root: dir);

      final hasTests = result.any((e) => e is File);

      if (hasTests) {
        dirsWithTests.add(dir);
      }
    }

    final dirs = {
      for (final dir in dirsWithTests) dir: dirTools[dir]!,
    };

    if (dirs.isEmpty) {
      logger.err('No tests found');
      return (null, ExitCode.unavailable);
    }

    return (dirs, null);
  }
}
