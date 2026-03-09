enum TransactionPriority {
  normal(1),
  flash(5);

  const TransactionPriority(this.value);
  final int value;
}
