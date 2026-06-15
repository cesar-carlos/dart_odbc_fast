import 'package:odbc_fast/domain/entities/param_value.dart' show ParamValue;
import 'package:odbc_fast/domain/helpers/param_value_conversion.dart'
    show paramValuesFromObjects;
import 'package:odbc_fast/domain/repositories/i_admin_repository.dart';
import 'package:odbc_fast/domain/repositories/i_connection_repository.dart';
import 'package:odbc_fast/domain/repositories/i_pool_repository.dart';
import 'package:odbc_fast/domain/repositories/i_query_repository.dart';
import 'package:odbc_fast/domain/repositories/i_transaction_repository.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show ParamValue;
import 'package:odbc_fast/odbc_fast.dart' show ParamValue;

export 'package:odbc_fast/domain/repositories/i_admin_repository.dart';
export 'package:odbc_fast/domain/repositories/i_connection_repository.dart';
export 'package:odbc_fast/domain/repositories/i_pool_repository.dart';
export 'package:odbc_fast/domain/repositories/i_query_repository.dart';
export 'package:odbc_fast/domain/repositories/i_transaction_repository.dart';

/// Aggregate repository contract composing focused capability interfaces.
///
/// **Typed parameters:** use [IQueryRepository.executeQueryParamValues],
/// [IQueryRepository.executePreparedParamValues], and
/// [IQueryRepository.executeQueryMultiParamValues] with explicit [ParamValue]
/// tags, or the `…FromObjects` / `…ParamValuesFromObjects` extension methods
/// on `IOdbcRepository` (see `odbc_repository_extensions.dart`, exported from
/// `package:odbc_fast/odbc_fast.dart`). Use [paramValuesFromObjects] when
/// building typed tag lists from plain Dart values.
///
/// Prefer depending on the narrower sub-interfaces
/// ([IConnectionRepository], [IQueryRepository], [ITransactionRepository],
/// [IPoolRepository], [IAdminRepository]) when a consumer only needs one
/// capability area.
abstract interface class IOdbcRepository
    implements
        IConnectionRepository,
        IQueryRepository,
        ITransactionRepository,
        IPoolRepository,
        IAdminRepository {}
