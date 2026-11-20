# Run on Windows with ODBC_TEST_DSN in the environment.
$ErrorActionPreference = 'Stop'
$template = Get-Content -Raw (Join-Path $PSScriptRoot 'large_result_read.sql')
Add-Type -ReferencedAssemblies System.Data -TypeDefinition @'
using System;
using System.Data.Odbc;
using System.Diagnostics;
public static class DirectResultRead {
    public static double[][] Measure(string dsn, string sql, bool text) {
        using (var conn = new OdbcConnection(dsn)) {
            conn.Open();
            using (var command = conn.CreateCommand()) {
                command.CommandText = sql;
                var result = new double[21];
                var firstRow = new double[21];
                var expected = new string('Z', 2048);
                for (int i = -4; i < result.Length; ++i) {
                    var ids = new int[512];
                    var amounts = new int[512];
                    var strings = new string[512];
                    var timer = Stopwatch.StartNew();
                    using (var reader = command.ExecuteReader()) {
                        int row = 0;
                        while (reader.Read()) {
                            if (row == 0 && i >= 0) firstRow[i] = timer.Elapsed.TotalMilliseconds * 1000;
                            ids[row] = reader.GetInt32(0);
                            amounts[row] = reader.GetInt32(1);
                            if (text && !reader.IsDBNull(2)) strings[row] = reader.GetString(2);
                            ++row;
                        }
                        timer.Stop();
                        if (row != ids.Length) throw new Exception("Incorrect row count");
                        for (int j = 0; j < row; ++j) {
                            if (ids[j] != j || amounts[j] != 3*j ||
                            (text && strings[j] != (j%7 == 0 ? null : expected)))
                            throw new Exception("Incorrect result");
                        }
                        if (i >= 0) result[i] = timer.Elapsed.TotalMilliseconds * 1000;
                    }
                }
                return new double[][] { result, firstRow };
            }
        }
    }
}
'@
$results = @{}
foreach ($text in $false,$true) {
    $projection = if ($text) { ", CASE WHEN id % 7 = 0 THEN NULL ELSE REPLICATE(CAST(N'Z' AS nvarchar(max)), 2048) END AS payload" } else { '' }
    $measurements = [DirectResultRead]::Measure($env:ODBC_TEST_DSN, $template.Replace('/*payload*/', $projection), $text)
    $results["direct_text_$text"] = $measurements[0]
    $results["direct_first_row_text_$text"] = $measurements[1]
}
$results | ConvertTo-Json
