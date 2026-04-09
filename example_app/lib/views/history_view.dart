import 'package:cs_beldex/cs_beldex.dart';
import 'package:flutter/material.dart';

import '../util.dart';

class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.wallet});

  final Wallet wallet;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  bool _loading = true;
  String? _error;
  List<Transaction> _transactions = const [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final txs = await widget.wallet.getAllTxs(refresh: true);
      txs.sort((a, b) => b.timeStamp.compareTo(a.timeStamp));

      if (!mounted) return;
      setState(() {
        _transactions = txs;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loadHistory,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Failed to load history: $_error'))
              : _transactions.isEmpty
                  ? const Center(child: Text('No transaction history found.'))
                  : ListView.separated(
                      itemCount: _transactions.length,
                      separatorBuilder: (_, __) => const Divider(height: 0),
                      itemBuilder: (context, index) {
                        final tx = _transactions[index];
                        final amount = formattedAmount(
                          tx.amount,
                          widget.wallet.runtimeType,
                        );
                        final sign = tx.isSpend ? '-' : '+';
                        final status = tx.isPending ? 'Pending' : 'Confirmed';

                        return ListTile(
                          leading: Icon(
                            tx.isSpend
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                          ),
                          title: Text('$sign$amount BDX'),
                          subtitle: Text(
                            '${tx.timeStamp.toLocal()}\n'
                            '$status • Confirms: ${tx.confirmations}\n'
                            'Hash: ${tx.hash}',
                          ),
                          isThreeLine: false,
                        );
                      },
                    ),
    );
  }
}
