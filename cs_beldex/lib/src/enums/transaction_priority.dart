enum TransactionPriority {
  normal(1),
  medium(2),
  flash(5);

  const TransactionPriority(this.value);
  final int value;
}
