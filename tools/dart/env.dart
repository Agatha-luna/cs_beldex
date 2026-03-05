import 'dart:io';

const kMoneroCRepo = "https://github.com/MogamboPuri/monero_c";
const kMoneroCHash = "1c8f89042dc4ee4e28d9ab9b6fd297212f84c310";

final envProjectDir =
    File.fromUri(Platform.script).parent.parent.parent.parent.path;

String get envToolsDir => "$envProjectDir${Platform.pathSeparator}tools";
String get envBuildDir => "$envProjectDir${Platform.pathSeparator}build";
String get envMoneroCDir => "$envBuildDir${Platform.pathSeparator}monero_c";
String get envOutputsDir =>
    "$envProjectDir${Platform.pathSeparator}built_outputs";