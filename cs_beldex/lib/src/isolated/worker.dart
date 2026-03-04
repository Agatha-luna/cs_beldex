import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:uuid/uuid.dart';

import '../ffi_bindings/beldex_wallet_bindings.dart' as bdx_ffi;
import '../ffi_bindings/beldex_wallet_manager_bindings.dart' as bdx_wm_ffi;
import '../logging.dart';

enum FuncName {
  createPolySeedWallet,
  createWallet,
  recoverWalletFromPolyseed,
  recoverWallet,
  recoverWalletFromKeys,
  restoreDeterministicWalletFromSpendKey,
  loadWallet,
  refreshCoins,
  refreshTransactions,
  transactionCount,
  getWalletBlockChainHeight,
  initWallet,
  isViewOnly,
  isConnectedToDaemon,
  isSynchronized,
  getWalletPath,
  getSeed,
  getSeedLanguage,
  getPrivateSpendKey,
  getPrivateViewKey,
  getPublicSpendKey,
  getPublicViewKey,
  getAddress,
  getDaemonBlockChainHeight,
  getWalletRefreshFromBlockHeight,
  setWalletRefreshFromBlockHeight,
  startSyncing,
  setLogLevel,
  stopSyncing,
  rescanBlockchainAsync,
  getBalance,
  getUnlockedBalance,
  getTxKey,
  getTx,
  getTxs,
  getAllTxs,
  getAllTxids,
  getOutputs,
  exportKeyImages,
  importKeyImages,
  freezeOutput,
  thawOutput,
  createTransaction,
  createTransactionMultiDest,
  commitTx,
  signMessage,
  verifyMessage,
  validateAddress,
  amountFromString,
  getPassword,
  changePassword,
  save,
  close,
  startPolling,
  stopPolling,
}

class Task {
  final String id = const Uuid().v4();
  final FuncName func;
  final Map<String, dynamic> args;

  Task({required this.func, this.args = const {}});
}

class Result<T> {
  final bool success;
  final T? value;
  final Object? error;

  Result({required this.success, this.value, this.error});
}

class Worker {
  final SendPort _commands;
  final ReceivePort _responses;
  final ReceivePort _events;
  final Map<String, Completer<dynamic>> _activeRequests = {};
  final StreamController<dynamic> _eventStream = StreamController.broadcast();
  Stream<dynamic> get eventStream => _eventStream.stream;

  Worker._(this._responses, this._commands, this._events) {
    _responses.listen(_handleResponsesFromIsolate);
    _events.listen((event) => _eventStream.add(event));
  }

  static Future<Worker> spawn() async {
    final initPort = ReceivePort();
    await Isolate.spawn(_startWorkerIsolate, initPort.sendPort);

    final commandPort = await initPort.first as SendPort;

    final receivePort = ReceivePort();
    final eventPort = ReceivePort();
    commandPort.send((receivePort.sendPort, eventPort.sendPort));

    return Worker._(receivePort, commandPort, eventPort);
  }

  Future<T> runTask<T>(Task task) async {
    final completer = Completer<T>.sync();
    _activeRequests[task.id] = completer;
    _commands.send(task);

    return await completer.future;
  }

  void _handleResponsesFromIsolate(dynamic message) {
    final (String id, dynamic value, Object? error) =
        message as (String, dynamic, Object?);
    final completer = _activeRequests.remove(id);
    if (completer == null) return;

    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(value);
    }
  }

  static void _startWorkerIsolate(SendPort mainSendPort) {
    final commandPort = ReceivePort();
    mainSendPort.send(commandPort.sendPort);

    late SendPort resultPort;
    late SendPort eventPort;

    Timer? pollingTimer;
    int? lastDaemonHeight;
    int? lastSyncHeight;
    int? lastBalanceUnlocked;
    int? lastBalanceFull;

    void startPolling(int wallet, int seconds) {
      pollingTimer?.cancel();

      final walletPointer = Pointer<Void>.fromAddress(wallet);

      pollingTimer = Timer.periodic(Duration(seconds: seconds), (_) async {
        final full = bdx_ffi.getWalletBalance(
          walletPointer,
          accountIndex: 0, // TODO
        );
        final unlocked = bdx_ffi.getWalletUnlockedBalance(
          walletPointer,
          accountIndex: 0, // TODO
        );

        if (unlocked != lastBalanceUnlocked || full != lastBalanceFull) {
          eventPort.send({
            "type": "onBalancesChanged",
            "full": full,
            "unlocked": unlocked,
          });
        }
        lastBalanceFull = full;
        lastBalanceUnlocked = unlocked;

        final nodeHeight = bdx_ffi.getDaemonBlockChainHeight(walletPointer);
        final heightChanged = nodeHeight != lastDaemonHeight;
        if (heightChanged) {
          eventPort.send({
            "type": "onNewBlock",
            "nodeHeight": nodeHeight,
          });
        }
        lastDaemonHeight = nodeHeight;

        final currentSyncingHeight =
            bdx_ffi.getWalletBlockChainHeight(walletPointer);

        if (currentSyncingHeight >= 0 &&
            currentSyncingHeight <= nodeHeight &&
            (heightChanged || currentSyncingHeight != lastSyncHeight)) {
          eventPort.send({
            "type": "onSyncingUpdate",
            "syncHeight": currentSyncingHeight,
            "nodeHeight": nodeHeight,
          });
        }
        lastSyncHeight = currentSyncingHeight;
      });
    }

    // Stop polling
    void stopPolling() {
      pollingTimer?.cancel();
      pollingTimer = null;
    }

    commandPort.listen((message) async {
      if (message is (SendPort, SendPort)) {
        (resultPort, eventPort) = message;
        return;
      }

      if (message is Task) {
        try {
          final dynamic result;

          switch (message.func) {
            case FuncName.startPolling:
              startPolling(
                message.args["wallet"] as int,
                message.args["seconds"] as int,
              );
              result = true;
              break;
            case FuncName.stopPolling:
              stopPolling();
              result = true;
              break;

            default:
              result = _executeTask(message);
          }

          resultPort.send((message.id, result, null));
        } catch (e) {
          resultPort.send((message.id, null, e));
        }
      }
    });
  }

  void dispose() {
    _eventStream.close();
    _responses.close();
    _events.close();
  }

  static dynamic _executeTask(Task task) {
    final args = task.args;
    return switch (task.func) {
      FuncName.createPolySeedWallet => _createPolySeedWallet(args),
      FuncName.createWallet => _createWallet(args),
      FuncName.recoverWalletFromPolyseed => _recoverWalletFromPolyseed(args),
      FuncName.recoverWallet => _recoverWallet(args),
      FuncName.recoverWalletFromKeys => _restoreWalletFromKeys(args),
      FuncName.restoreDeterministicWalletFromSpendKey =>
        _restoreDeterministicWalletFromSpendKey(args),
      FuncName.loadWallet => _openWallet(args),
      FuncName.refreshCoins => _refreshCoins(args),
      FuncName.refreshTransactions => _refreshTransactions(args),
      FuncName.transactionCount => _transactionCount(args),
      FuncName.getWalletBlockChainHeight => _getWalletBlockChainHeight(args),
      FuncName.initWallet => _initWallet(args),
      FuncName.isViewOnly => _isViewOnly(args),
      FuncName.isConnectedToDaemon => _isConnectedToDaemon(args),
      FuncName.isSynchronized => _isSynchronized(args),
      FuncName.getWalletPath => _getWalletPath(args),
      FuncName.getSeed => _getSeed(args),
      FuncName.getSeedLanguage => _getSeedLanguage(args),
      FuncName.getPrivateSpendKey => _getPrivateSpendKey(args),
      FuncName.getPrivateViewKey => _getPrivateViewKey(args),
      FuncName.getPublicSpendKey => _getPublicSpendKey(args),
      FuncName.getPublicViewKey => _getPublicViewKey(args),
      FuncName.getAddress => _getAddress(args),
      FuncName.getDaemonBlockChainHeight => _getDaemonBlockChainHeight(args),
      FuncName.getWalletRefreshFromBlockHeight =>
        _getWalletRefreshFromBlockHeight(args),
      FuncName.setWalletRefreshFromBlockHeight =>
        _setRefreshFromBlockHeight(args),
      FuncName.startSyncing => _startSyncing(args),
      FuncName.setLogLevel => _setLogLevel(args),
      FuncName.stopSyncing => _stopSyncing(args),
      FuncName.rescanBlockchainAsync => _rescanWalletBlockchainAsync(args),
      FuncName.getBalance => _getBalance(args),
      FuncName.getUnlockedBalance => _getUnlockedBalance(args),
      FuncName.getTxKey => _getTxKey(args),
      FuncName.getTx => _getTx(args),
      FuncName.getTxs => _getTxs(args),
      FuncName.getAllTxs => _getAllTxs(args),
      FuncName.getAllTxids => _getAllTxids(args),
      FuncName.getOutputs => _getOutputs(args),
      FuncName.exportKeyImages => _exportKeyImages(args),
      FuncName.importKeyImages => _importKeyImages(args),
      FuncName.freezeOutput => _freezeOutput(args),
      FuncName.thawOutput => _thawOutput(args),
      FuncName.createTransaction => _createTransaction(args),
      FuncName.createTransactionMultiDest => _createTransactionMultiDest(args),
      FuncName.commitTx => _commitTx(args),
      FuncName.signMessage => _signMessage(args),
      FuncName.verifyMessage => _verifyMessage(args),
      FuncName.validateAddress => _validateAddress(args),
      FuncName.amountFromString => _amountFromString(args),
      FuncName.getPassword => _getPassword(args),
      FuncName.changePassword => _changePassword(args),
      FuncName.save => _save(args),
      FuncName.close => _close(args),
      FuncName.startPolling =>
        throw ArgumentError("Start polling should not be run here"),
      FuncName.stopPolling =>
        throw ArgumentError("Stop polling should not be run here"),
    };
  }
}

int _createPolySeedWallet(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final language = args["lang"] as String;
  final path = args["path"] as String;
  final password = args["pw"] as String;
  final seedOffset = args["offset"] as String;
  final networkType = args["net"] as int;

  final seed = bdx_ffi.createPolyseed(language: language);
  final walletPointer = bdx_wm_ffi.createWalletFromPolyseed(
    wmPointer,
    path: path,
    password: password,
    mnemonic: seed,
    seedOffset: seedOffset,
    newWallet: true,
    networkType: networkType,
    restoreHeight: 0, // ignored by core underlying code
    kdfRounds: 1,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _createWallet(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final language = args["lang"] as String;
  final path = args["path"] as String;
  final password = args["pw"] as String;
  final networkType = args["net"] as int;

  final walletPointer = bdx_wm_ffi.createWallet(
    wmPointer,
    path: path,
    password: password,
    networkType: networkType,
    language: language,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _recoverWallet(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final path = args["path"] as String;
  final password = args["pw"] as String;
  final networkType = args["net"] as int;
  final restoreHeight = args["height"] as int;
  final seed = args["seed"] as String;
  final seedOffset = args["offset"] as String;

  final walletPointer = bdx_wm_ffi.recoveryWallet(
    wmPointer,
    path: path,
    password: password,
    networkType: networkType,
    seedOffset: seedOffset,
    mnemonic: seed,
    restoreHeight: restoreHeight,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _recoverWalletFromPolyseed(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final path = args["path"] as String;
  final seed = args["seed"] as String;
  final password = args["pw"] as String;
  final seedOffset = args["offset"] as String;
  final networkType = args["net"] as int;

  final walletPointer = bdx_wm_ffi.createWalletFromPolyseed(
    wmPointer,
    path: path,
    password: password,
    mnemonic: seed,
    seedOffset: seedOffset,
    newWallet: false,
    networkType: networkType,
    restoreHeight: 0, // ignored by core underlying code
    kdfRounds: 1,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _restoreWalletFromKeys(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final path = args["path"] as String;
  final language = args["lang"] as String;
  final viewKey = args["vk"] as String;
  final password = args["pw"] as String;
  final spendKey = args["sp"] as String;
  final address = args["addr"] as String;
  final networkType = args["net"] as int;
  final restoreHeight = args["height"] as int;

  final walletPointer = bdx_wm_ffi.createWalletFromKeys(
    wmPointer,
    path: path,
    password: password,
    language: language,
    addressString: address,
    viewKeyString: viewKey,
    spendKeyString: spendKey,
    networkType: networkType,
    restoreHeight: restoreHeight,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _restoreDeterministicWalletFromSpendKey(Map<String, dynamic> args) {
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final path = args["path"] as String;
  final language = args["lang"] as String;
  final password = args["pw"] as String;
  final spendKey = args["sp"] as String;
  final networkType = args["net"] as int;
  final restoreHeight = args["height"] as int;

  final walletPointer = bdx_wm_ffi.createDeterministicWalletFromSpendKey(
    wmPointer,
    path: path,
    password: password,
    language: language,
    newWallet: true,
    spendKeyString: spendKey,
    networkType: networkType,
    restoreHeight: restoreHeight,
    kdfRounds: 1,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

int _openWallet(Map<String, dynamic> args) {
  Logging.log?.i("Opening wallet ${args["path"]} from _openWallet");
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final path = args["path"] as String;
  final password = args["pw"] as String;
  final networkType = args["net"] as int;

  final walletPointer = bdx_wm_ffi.openWallet(
    wmPointer,
    path: path,
    password: password,
    networkType: networkType,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  bdx_ffi.storeWallet(walletPointer, path: path);

  return walletPointer.address;
}

void _refreshCoins(Map<String, dynamic> args) {
  Logging.log?.i("Refreshing coins for wallet ${args["wp"]} from _refreshCoins");
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final coinsPointer = bdx_ffi.getCoinsPointer(walletPointer);
  bdx_ffi.refreshCoins(coinsPointer);
}

void _refreshTransactions(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final txHistoryPtr = bdx_ffi.getTransactionHistoryPointer(walletPointer);
  bdx_ffi.refreshTransactionHistory(txHistoryPtr);
}

int _transactionCount(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final txHistoryPtr = bdx_ffi.getTransactionHistoryPointer(walletPointer);
  return bdx_ffi.getTransactionHistoryCount(txHistoryPtr);
}

int _getWalletBlockChainHeight(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletBlockChainHeight(walletPointer);
}

bool _initWallet(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final daemonAddress = args["addr"] as String;
  final daemonUsername = args["u"] as String;
  final daemonPassword = args["p"] as String;
  final socksProxyAddress = args["sock"] as String;
  final useSSL = args["ssl"] as bool;
  final isLightWallet = args["lite"] as bool;
  final trusted = args["trust"] as bool;

  final init = bdx_ffi.initWallet(
    walletPointer,
    daemonAddress: daemonAddress,
    daemonUsername: daemonUsername,
    daemonPassword: daemonPassword,
    proxyAddress: socksProxyAddress,
    useSsl: useSSL,
    lightWallet: isLightWallet,
  );

  bdx_ffi.checkWalletStatus(walletPointer);

  if (init) {
    bdx_ffi.setTrustedDaemon(walletPointer, arg: trusted);
  }

  return init;
}

bool _isViewOnly(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.isWatchOnly(walletPointer);
}

int _isConnectedToDaemon(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.isConnected(walletPointer);
}

bool _isSynchronized(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.isSynchronized(walletPointer);
}

String _getWalletPath(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletPath(walletPointer);
}

String _getSeed(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final seedOffset = args["offset"] as String;
  final polySeed = bdx_ffi.getWalletPolyseed(
    walletPointer,
    passphrase: seedOffset,
  );
  if (polySeed != "") {
    return polySeed;
  }
  final legacy = bdx_ffi.getWalletSeed(
    walletPointer,
    seedOffset: seedOffset,
  );
  return legacy;
}

String _getSeedLanguage(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletSeedLanguage(walletPointer);
}

String _getPrivateSpendKey(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletSecretSpendKey(walletPointer);
}

String _getPrivateViewKey(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletSecretViewKey(walletPointer);
}

String _getPublicSpendKey(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletPublicSpendKey(walletPointer);
}

String _getPublicViewKey(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletPublicViewKey(walletPointer);
}

String _getAddress(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final addressIndex = args["idx"] as int;
  final accountIndex = args["acc"] as int;
  return bdx_ffi.getWalletAddress(
    walletPointer,
    accountIndex: accountIndex,
    addressIndex: addressIndex,
  );
}

int _getDaemonBlockChainHeight(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getDaemonBlockChainHeight(walletPointer);
}

int _getWalletRefreshFromBlockHeight(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.getWalletRefreshFromBlockHeight(walletPointer);
}

void _setRefreshFromBlockHeight(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final refreshFromBlockHeight = args["height"] as int;
  bdx_ffi.setWalletRefreshFromBlockHeight(
    walletPointer,
    refreshFromBlockHeight: refreshFromBlockHeight,
  );
}

void _startSyncing(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final millis = args["millis"] as int;
  bdx_ffi.setWalletAutoRefreshInterval(walletPointer, millis: millis);
  bdx_ffi.refreshWalletAsync(walletPointer);
  return bdx_ffi.startWalletRefresh(walletPointer);
}

void _setLogLevel(Map<String, dynamic> args) {
  final level = args["level"] as int;
  bdx_ffi.setLogLevel(level);
}

void _stopSyncing(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  bdx_ffi.pauseWalletRefresh(walletPointer);
  bdx_ffi.stopWallet(walletPointer);
}

void _rescanWalletBlockchainAsync(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final result = bdx_ffi.rescanWalletBlockchainAsync(walletPointer);
  return result;
}

int _getBalance(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final accountIndex = args["acc"] as int;
  return bdx_ffi.getWalletBalance(walletPointer, accountIndex: accountIndex);
}

int _getUnlockedBalance(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final accountIndex = args["acc"] as int;
  return bdx_ffi.getWalletUnlockedBalance(
    walletPointer,
    accountIndex: accountIndex,
  );
}

String _getTxKey(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final txid = args["txid"] as String;
  return bdx_ffi.getTxKey(walletPointer, txid: txid);
}

Map<String, dynamic> _getTx(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final txid = args["txid"] as String;
  final refresh = args["refresh"] as bool;
  final txHistoryPointer = bdx_ffi.getTransactionHistoryPointer(walletPointer);

  if (refresh) {
    bdx_ffi.refreshTransactionHistory(txHistoryPointer);
  }

  final infoPointer =
      bdx_ffi.getTransactionInfoPointerByTxid(txHistoryPointer, txid: txid);

  return {
    "displayLabel": bdx_ffi.getTransactionInfoLabel(infoPointer),
    "description": bdx_ffi.getTransactionInfoDescription(infoPointer),
    "fee": bdx_ffi.getTransactionInfoFee(infoPointer).toString(),
    "confirmations": bdx_ffi.getTransactionInfoConfirmations(infoPointer),
    "blockHeight": bdx_ffi.getTransactionInfoBlockHeight(infoPointer),
    "accountIndex": bdx_ffi.getTransactionInfoAccount(infoPointer),
    "addressIndexes":
        bdx_ffi.getTransactionSubaddressIndexes(infoPointer).toList(),
    "paymentId": bdx_ffi.getTransactionInfoPaymentId(infoPointer),
    "amount": bdx_ffi.getTransactionInfoAmount(infoPointer).toString(),
    "isSpend": bdx_ffi.getTransactionInfoIsSpend(infoPointer),
    "hash": bdx_ffi.getTransactionInfoHash(infoPointer),
    "key": bdx_ffi.getTxKey(walletPointer, txid: txid),
    "timeStamp": bdx_ffi.getTransactionInfoTimestamp(infoPointer),
  };
}

List<Map<String, dynamic>> _getTxs(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final refresh = args["refresh"] as bool;
  final txids = args["txids"] as List<String>;
  final txHistoryPointer = bdx_ffi.getTransactionHistoryPointer(walletPointer);

  if (refresh) {
    bdx_ffi.refreshTransactionHistory(txHistoryPointer);
  }

  final List<Map<String, dynamic>> results = [];

  for (final txid in txids) {
    final infoPointer =
        bdx_ffi.getTransactionInfoPointerByTxid(txHistoryPointer, txid: txid);

    results.add({
      "displayLabel": bdx_ffi.getTransactionInfoLabel(infoPointer),
      "description": bdx_ffi.getTransactionInfoDescription(infoPointer),
      "fee": bdx_ffi.getTransactionInfoFee(infoPointer).toString(),
      "confirmations": bdx_ffi.getTransactionInfoConfirmations(infoPointer),
      "blockHeight": bdx_ffi.getTransactionInfoBlockHeight(infoPointer),
      "accountIndex": bdx_ffi.getTransactionInfoAccount(infoPointer),
      "addressIndexes":
          bdx_ffi.getTransactionSubaddressIndexes(infoPointer).toList(),
      "paymentId": bdx_ffi.getTransactionInfoPaymentId(infoPointer),
      "amount": bdx_ffi.getTransactionInfoAmount(infoPointer).toString(),
      "isSpend": bdx_ffi.getTransactionInfoIsSpend(infoPointer),
      "hash": bdx_ffi.getTransactionInfoHash(infoPointer),
      "key": bdx_ffi.getTxKey(walletPointer, txid: txid),
      "timeStamp": bdx_ffi.getTransactionInfoTimestamp(infoPointer),
    });
  }

  return results;
}

List<Map<String, dynamic>> _getAllTxs(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final refresh = args["refresh"] as bool;
  final txHistoryPointer = bdx_ffi.getTransactionHistoryPointer(walletPointer);

  if (refresh) {
    bdx_ffi.refreshTransactionHistory(txHistoryPointer);
  }

  final count = bdx_ffi.getTransactionHistoryCount(txHistoryPointer);

  final List<Map<String, dynamic>> results = [];

  final txids = List.generate(
    count,
    (index) => bdx_ffi.getTransactionInfoHash(
      bdx_ffi.getTransactionInfoPointer(
        txHistoryPointer,
        index: index,
      ),
    ),
  );

  for (final txid in txids) {
    final infoPointer =
        bdx_ffi.getTransactionInfoPointerByTxid(txHistoryPointer, txid: txid);

    results.add({
      "displayLabel": bdx_ffi.getTransactionInfoLabel(infoPointer),
      "description": bdx_ffi.getTransactionInfoDescription(infoPointer),
      "fee": bdx_ffi.getTransactionInfoFee(infoPointer).toString(),
      "confirmations": bdx_ffi.getTransactionInfoConfirmations(infoPointer),
      "blockHeight": bdx_ffi.getTransactionInfoBlockHeight(infoPointer),
      "accountIndex": bdx_ffi.getTransactionInfoAccount(infoPointer),
      "addressIndexes":
          bdx_ffi.getTransactionSubaddressIndexes(infoPointer).toList(),
      "paymentId": bdx_ffi.getTransactionInfoPaymentId(infoPointer),
      "amount": bdx_ffi.getTransactionInfoAmount(infoPointer).toString(),
      "isSpend": bdx_ffi.getTransactionInfoIsSpend(infoPointer),
      "hash": bdx_ffi.getTransactionInfoHash(infoPointer),
      "key": bdx_ffi.getTxKey(walletPointer, txid: txid),
      "timeStamp": bdx_ffi.getTransactionInfoTimestamp(infoPointer),
    });
  }

  return results;
}

List<String> _getAllTxids(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final refresh = args["refresh"] as bool;
  final txHistoryPointer = bdx_ffi.getTransactionHistoryPointer(walletPointer);

  if (refresh) {
    bdx_ffi.refreshTransactionHistory(txHistoryPointer);
  }

  final count = bdx_ffi.getTransactionHistoryCount(txHistoryPointer);

  return List.generate(
    count,
    (index) => bdx_ffi.getTransactionInfoHash(
      bdx_ffi.getTransactionInfoPointer(
        txHistoryPointer,
        index: index,
      ),
    ),
  );
}

List<Map<String, dynamic>> _getOutputs(Map<String, dynamic> args) {
  Logging.log?.i("Getting outputs for wallet ${args["wp"]} from _getOutputs");
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final refresh = args["refresh"] as bool;
  final includeSpent = args["includeSpent"] as bool;

  final coinsPointer = bdx_ffi.getCoinsPointer(walletPointer);

  if (refresh) {
    bdx_ffi.refreshCoins(coinsPointer);
  }

  final count = bdx_ffi.getCoinsCount(coinsPointer);

  final result = <Map<String, dynamic>>[];

  for (int i = 0; i < count; i++) {
    final coinInfoPointer = bdx_ffi.getCoinInfoPointer(coinsPointer, i);

    final hash = bdx_ffi.getHashForCoinsInfo(coinInfoPointer);

    if (hash.isNotEmpty) {
      final spent = bdx_ffi.isSpentCoinsInfo(coinInfoPointer);

      if (includeSpent || !spent) {
        final utxo = {
          "address": bdx_ffi.getAddressForCoinsInfo(coinInfoPointer),
          "hash": hash,
          "keyImage": bdx_ffi.getKeyImageForCoinsInfo(coinInfoPointer),
          "value": bdx_ffi.getAmountForCoinsInfo(coinInfoPointer),
          "isFrozen": bdx_ffi.isFrozenCoinsInfo(coinInfoPointer),
          "isUnlocked": bdx_ffi.isUnlockedCoinsInfo(coinInfoPointer),
          "vout": bdx_ffi.getInternalOutputIndexForCoinsInfo(coinInfoPointer),
          "spent": spent,
          "spentHeight": spent
              ? bdx_ffi.getSpentHeightForCoinsInfo(coinInfoPointer)
              : null,
          "height": bdx_ffi.getBlockHeightForCoinsInfo(coinInfoPointer),
          "coinbase": bdx_ffi.isCoinbaseCoinsInfo(coinInfoPointer),
        };

        result.add(utxo);
      }
    } else {
      Logging.log?.w("Found empty hash in beldex utxo?!");
    }
  }

  return result;
}

bool _exportKeyImages(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final filename = args["fname"] as String;
  final all = args["all"] as bool;
  return bdx_ffi.exportWalletKeyImages(walletPointer, filename, all: all);
}

bool _importKeyImages(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final filename = args["fname"] as String;
  return bdx_ffi.importWalletKeyImages(walletPointer, filename);
}

void _freezeOutput(Map<String, dynamic> args) {
  final keyImage = args["ki"] as String;
  if (keyImage.isEmpty) {
    throw Exception("Attempted freeze of empty keyImage");
  }
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final coinsPointer = bdx_ffi.getCoinsPointer(walletPointer);

  final count = bdx_ffi.getAllCoinsSize(coinsPointer);

  for (int i = 0; i < count; i++) {
    if (keyImage ==
        bdx_ffi.getKeyImageForCoinsInfo(
          bdx_ffi.getCoinInfoPointer(coinsPointer, i),
        )) {
      bdx_ffi.freezeCoin(coinsPointer, index: i);
      return;
    }
  }

  throw Exception(
    "No matching keyImage found",
  );
}

void _thawOutput(Map<String, dynamic> args) {
  final keyImage = args["ki"] as String;
  if (keyImage.isEmpty) {
    throw Exception("Attempted thaw of empty keyImage");
  }
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final coinsPointer = bdx_ffi.getCoinsPointer(walletPointer);

  final count = bdx_ffi.getAllCoinsSize(coinsPointer);

  for (int i = 0; i < count; i++) {
    if (keyImage ==
        bdx_ffi.getKeyImageForCoinsInfo(
          bdx_ffi.getCoinInfoPointer(coinsPointer, i),
        )) {
      bdx_ffi.thawCoin(coinsPointer, index: i);
      return;
    }
  }

  throw Exception(
    "No matching keyImage found",
  );
}

Map<String, dynamic> _createTransaction(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);

  final recipientAddress = args["addr"] as String;
  final amount = args["amt"] as int;
  final subaddressAccount = args["acc"] as int;
  final pendingTransactionPriority = args["prio"] as int;
  final paymentId = args["pid"] as String;
  final sweep = args["sweep"] as bool;
  final inputs = args["kis"] as List<String>;

  final pendingTxPointer = bdx_ffi.createTransaction(
    walletPointer,
    address: recipientAddress,
    paymentId: paymentId,
    amount: sweep ? 0 : amount,
    pendingTransactionPriority: pendingTransactionPriority,
    subaddressAccount: subaddressAccount,
    preferredInputs: inputs,
  );

  bdx_ffi.checkPendingTransactionStatus(pendingTxPointer);

  return {
    "amount": bdx_ffi.getPendingTransactionAmount(pendingTxPointer),
    "fee": bdx_ffi.getPendingTransactionFee(pendingTxPointer),
    "txid": bdx_ffi.getPendingTransactionTxid(pendingTxPointer),
    "hex": bdx_ffi.getPendingTransactionHex(pendingTxPointer),
    "pointerAddress": pendingTxPointer.address,
  };
}

Map<String, dynamic> _createTransactionMultiDest(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);

  final recipientAddresses = args["addrs"] as List<String>;
  final amounts = args["amts"] as List<int>;
  final subaddressAccount = args["acc"] as int;
  final pendingTransactionPriority = args["prio"] as int;
  final paymentId = args["pid"] as String;
  final sweep = args["sweep"] as bool;
  final inputs = args["kis"] as List<String>;

  final pendingTxPointer = bdx_ffi.createTransactionMultiDest(
    walletPointer,
    addresses: recipientAddresses,
    paymentId: paymentId,
    amounts: amounts,
    pendingTransactionPriority: pendingTransactionPriority,
    subaddressAccount: subaddressAccount,
    preferredInputs: inputs,
    isSweepAll: sweep,
  );

  bdx_ffi.checkPendingTransactionStatus(pendingTxPointer);

  return {
    "amount": bdx_ffi.getPendingTransactionAmount(pendingTxPointer),
    "fee": bdx_ffi.getPendingTransactionFee(pendingTxPointer),
    "txid": bdx_ffi.getPendingTransactionTxid(pendingTxPointer),
    "hex": bdx_ffi.getPendingTransactionHex(pendingTxPointer),
    "pointerAddress": pendingTxPointer.address,
  };
}

bool _commitTx(Map<String, dynamic> args) {
  final pendingTxPointer = Pointer<Void>.fromAddress(args["ptr"] as int);
  final result = bdx_ffi.commitPendingTransaction(
    pendingTxPointer,
  );

  bdx_ffi.checkPendingTransactionStatus(pendingTxPointer);

  return result;
}

String _signMessage(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final address = args["addr"] as String;
  final message = args["msg"] as String;
  return bdx_ffi.signMessageWith(
    walletPointer,
    message: message,
    address: address,
  );
}

bool _verifyMessage(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final address = args["addr"] as String;
  final message = args["msg"] as String;
  final signature = args["sig"] as String;

  return bdx_ffi.verifySignedMessageWithWallet(
    walletPointer,
    message: message,
    address: address,
    signature: signature,
  );
}

bool _validateAddress(Map<String, dynamic> args) {
  final address = args["addr"] as String;
  final networkType = args["net"] as int;
  return bdx_ffi.validateAddress(address, networkType);
}

int _amountFromString(Map<String, dynamic> args) {
  return bdx_ffi.amountFromString(args["amt"] as String);
}

String _getPassword(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);

  return bdx_ffi.getWalletPassword(walletPointer);
}

bool _changePassword(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final newPassword = args["pw"] as String;

  return bdx_ffi.setWalletPassword(walletPointer, password: newPassword);
}

bool _save(Map<String, dynamic> args) {
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  return bdx_ffi.storeWallet(walletPointer, path: "");
}

void _close(Map<String, dynamic> args) {
  Logging.log?.i("Closing wallet ${args["wp"]} from _close");
  final wmPointer = Pointer<Void>.fromAddress(args["wm"] as int);
  final walletPointer = Pointer<Void>.fromAddress(args["wp"] as int);
  final save = args["save"] as bool;

  if (save) {
    bdx_ffi.storeWallet(walletPointer, path: "");
  }

  bdx_wm_ffi.closeWallet(wmPointer, walletPointer, save);
}
