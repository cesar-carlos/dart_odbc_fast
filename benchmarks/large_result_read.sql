WITH digits(n) AS (
    SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(n)
), numbers AS (
    SELECT a.n + b.n * 10 + c.n * 100 AS id
    FROM digits a CROSS JOIN digits b CROSS JOIN digits c
)
SELECT id, id * 3 AS amount /*payload*/
FROM numbers WHERE id < 512 ORDER BY id
