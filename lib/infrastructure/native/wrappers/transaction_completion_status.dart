/// Optional raw completion status used by the native transaction wrapper.
/// Legacy backends keep using the boolean transaction methods.
abstract interface class TransactionCompletionStatus {
  int commitTransactionStatus(int txnId);

  int rollbackTransactionStatus(int txnId);
}
