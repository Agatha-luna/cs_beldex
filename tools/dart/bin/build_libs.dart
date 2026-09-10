import 'dart:io';
import 'dart:math';

import '../create_framework.dart';
import '../env.dart';
import '../util.dart';

void main(List<String> args) async {
  const platforms = ["android", "ios", "macos", "linux", "windows"];
  const coins = ["beldex"];

  if (args.length != 1) {
    throw ArgumentError(
      "Missing platform argument. Expected one of $platforms",
    );
  }
  final platform = args.first;
  if (!platforms.contains(args.first)) {
    throw ArgumentError(args.first);
  }

  final moneroCDir = Directory(envMoneroCDir);
  if (!moneroCDir.existsSync()) {
    l("Did not find monero_c. Calling prepare_monero_c.dart...");
    await runAsync(
      "dart",
      [
        "$envToolsDir"
            "${Platform.pathSeparator}dart"
            "${Platform.pathSeparator}bin"
            "${Platform.pathSeparator}prepare_monero_c.dart",
      ],
    );
  }

  final thisDir = Directory.current;
  Directory.current = moneroCDir;

  final nProc = _getNProc(platform);
  final triples = _getTriples(platform);
  final bt = _getBinType(platform);

  for (final triple in triples) {
    for (final coin in coins) {
      await runAsync("./build_single.sh", [coin, triple, "-j$nProc"]);

      final destDir = Directory(
        "$envMoneroCDir"
        "${Platform.pathSeparator}release"
        "${Platform.pathSeparator}$coin",
      )..createSync(recursive: true);
      final destPath = "${destDir.path}"
          "${Platform.pathSeparator}${triple}_libwallet2_api_c.$bt";

      // build_single.sh drops the built artifact under a git-describe
      // tagged directory (release/<tag>/<triple>/lib<coin>_wallet2_api_c.<ext>)
      // rather than the flat path the rest of this pipeline expects, so
      // locate it and copy it into place.
      final releaseDir = Directory(
        "$envMoneroCDir${Platform.pathSeparator}release",
      );
      File? built;
      for (final entry in releaseDir.listSync()) {
        if (entry is! Directory) continue;
        final candidate = File(
          "${entry.path}"
          "${Platform.pathSeparator}$triple"
          "${Platform.pathSeparator}lib${coin}_wallet2_api_c.$bt",
        );
        if (candidate.existsSync()) {
          built = candidate;
          break;
        }
      }
      if (built == null) {
        throw Exception(
          "Could not find built artifact for $coin/$triple under "
          "${releaseDir.path}",
        );
      }
      built.copySync(destPath);
    }
  }

  Directory.current = thisDir;

  final builtOutputsDirPath = "$envOutputsDir"
      "${Platform.pathSeparator}$platform";

  // copy to built_outputs as required
  switch (platform) {
    case "android":
      final triples = _getTriples("android");
      final basePath = "$builtOutputsDirPath"
          "${Platform.pathSeparator}jniLibs";

      for (final triple in triples) {
        final mapping = _mapAndroid(triple);
        final dir = Directory(
          "$basePath"
          "${Platform.pathSeparator}$mapping",
        )..createSync(
            recursive: true,
          );
        for (final coin in coins) {
          await runAsync(
            "cp",
            [
              "$envMoneroCDir"
                  "${Platform.pathSeparator}release"
                  "${Platform.pathSeparator}$coin"
                  "${Platform.pathSeparator}${triple}_libwallet2_api_c.so",
              "${dir.path}"
                  "${Platform.pathSeparator}lib${coin}_libwallet2_api_c.so",
            ],
          );
        }
      }

      break;

    case "ios":
    case "macos":
      final dir = Directory(
        "$builtOutputsDirPath"
        "${Platform.pathSeparator}Frameworks",
      )..createSync(
          recursive: true,
        );

      // ios and macos only have 1 triple currently
      final triple = _getTriples(platform).first;

      final String bdxDylib;
      if (platform == "ios") {
        bdxDylib = "$envMoneroCDir"
            "${Platform.pathSeparator}release"
            "${Platform.pathSeparator}beldex"
            "${Platform.pathSeparator}${triple}_libwallet2_api_c.dylib";
      } else {
        bdxDylib = "$envMoneroCDir"
            "${Platform.pathSeparator}release"
            "${Platform.pathSeparator}beldex"
            "${Platform.pathSeparator}${triple}_libwallet2_api_c.dylib";
      }

      await createFramework(
        frameworkName: "BeldexWallet",
        pathToDylib: bdxDylib,
        targetDirFrameworks: dir.path,
      );

      break;

    case "linux":
      final dir = Directory(builtOutputsDirPath)
        ..createSync(
          recursive: true,
        );
      for (final coin in coins) {
        await runAsync(
          "cp",
          [
            "$envMoneroCDir"
                "${Platform.pathSeparator}release"
                "${Platform.pathSeparator}$coin"
                "${Platform.pathSeparator}x86_64-linux-gnu_libwallet2_api_c.so",
            "${dir.path}"
                "${Platform.pathSeparator}${coin}_libwallet2_api_c.so",
          ],
        );
      }
      break;

    case "windows":
      final dir = Directory(builtOutputsDirPath)
        ..createSync(
          recursive: true,
        );
      await runAsync(
        "cp",
        [
          "$envMoneroCDir"
              "${Platform.pathSeparator}release"
              "${Platform.pathSeparator}beldex"
              "${Platform.pathSeparator}x86_64-w64-mingw32_libwallet2_api_c.dll",
          "${dir.path}"
              "${Platform.pathSeparator}beldex_libwallet2_api_c.dll",
        ],
      );

      // These are mingw toolchain runtime DLLs (not built by this project) —
      // pulled directly from contrib/depends rather than from the release
      // dir, since build_single.sh no longer copies them there itself.
      final sspPath = "$envMoneroCDir"
          "${Platform.pathSeparator}contrib"
          "${Platform.pathSeparator}depends"
          "${Platform.pathSeparator}x86_64-w64-mingw32"
          "${Platform.pathSeparator}lib"
          "${Platform.pathSeparator}libssp-0.dll";

      await runAsync(
        "cp",
        [
          sspPath,
          "${dir.path}"
              "${Platform.pathSeparator}libssp-0.dll",
        ],
      );

      final pThreadPath = "$envMoneroCDir"
          "${Platform.pathSeparator}contrib"
          "${Platform.pathSeparator}depends"
          "${Platform.pathSeparator}x86_64-w64-mingw32"
          "${Platform.pathSeparator}sysroot"
          "${Platform.pathSeparator}usr"
          "${Platform.pathSeparator}x86_64-w64-mingw32"
          "${Platform.pathSeparator}bin"
          "${Platform.pathSeparator}libwinpthread-1.dll";

      await runAsync(
        "cp",
        [
          pThreadPath,
          "${dir.path}"
              "${Platform.pathSeparator}libwinpthread-1.dll",
        ],
      );
      break;

    default:
      throw Exception("Not sure how you got this far tbh");
  }
}

String _mapAndroid(String triple) {
  switch (triple) {
    case "x86_64-linux-android":
      return "x86_64";
    case "aarch64-linux-android":
      return "arm64-v8a";
    case "armv7a-linux-androideabi":
      return "armeabi-v7a";
    default:
      throw ArgumentError("Unsupported triple: $triple");
  }
}

List<String> _getTriples(String platform) {
  switch (platform) {
    case "android":
      return [
        "x86_64-linux-android",
        "armv7a-linux-androideabi",
        "aarch64-linux-android",
      ];

    case "ios":
      return ["aarch64-apple-ios"];

    case "macos":
      return ["aarch64-apple-darwin"];

    case "linux":
      return ["x86_64-linux-gnu"];

    case "windows":
      return ["x86_64-w64-mingw32"];

    default:
      throw ArgumentError(platform, "platform");
  }
}

String _getNProc(String platform) {
  final int nProc;
  if (platform == "ios" || platform == "macos") {
    final result = Process.runSync("sysctl", ["-n", "hw.physicalcpu"]);
    if (result.exitCode != 0) {
      throw Exception("code=${result.exitCode}, stderr=${result.stderr}");
    }
    nProc = int.parse(result.stdout.toString());
  } else {
    final result = Process.runSync("nproc", []);
    if (result.exitCode != 0) {
      throw Exception("code=${result.exitCode}, stderr=${result.stderr}");
    }
    nProc = int.parse(result.stdout.toString());
  }

  switch (platform) {
    case "android":
    case "linux":
      return max(1, (nProc * 0.8).floor()).toString();

    case "ios":
    case "macos":
    case "windows":
      return nProc.toString();

    default:
      throw ArgumentError(platform, "platform");
  }
}

String _getBinType(String platform) {
  switch (platform) {
    case "android":
    case "linux":
      return "so";

    case "windows":
      return "dll";

    case "ios":
    case "macos":
      return "dylib";

    default:
      throw ArgumentError(platform, "platform");
  }
}