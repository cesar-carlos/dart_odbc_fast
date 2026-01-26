enum IsolationLevel {
  readUncommitted(0),
  readCommitted(1),
  repeatableRead(2),
  serializable(3);

  const IsolationLevel(this.value);
  final int value;
}
