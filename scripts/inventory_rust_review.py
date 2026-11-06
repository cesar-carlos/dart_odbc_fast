"""Inventory Rust review evidence without inferring review from test results."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'doc/development'
LEDGER = DOCS / 'rust_review_ledger.json'
SNAPSHOT = DOCS / 'rust_review_inventory.json'
REPORT = DOCS / 'RUST_REVIEW_INVENTORY.md'
LABELS = {'integral': 'Integral', 'parcial': 'Parcial', 'nao_revisado': 'Não revisado'}
LEVELS = {
    'targeted_validation': 'Revisão focal com testes/benchmarks',
    'preliminary_inspection': 'Triagem preliminar',
    'support_validation': 'Validação de apoio',
    'none': 'Sem evidência de revisão',
}


def source_text(path: Path) -> str:
    return path.read_text(encoding='utf-8').replace('\r\n', '\n').replace('\r', '\n')


def source_hash(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def category(path: str) -> str:
    parts = Path(path).parts
    name = parts[-1]
    if 'tests' in parts or name == 'tests.rs' or name.endswith(('_test.rs', '_tests.rs')):
        return 'testes'
    if 'benches' in parts or name == 'compression_paired_bench.rs':
        return 'benchmarks'
    if 'examples' in parts:
        return 'exemplos'
    if name == 'build.rs':
        return 'build'
    if path.startswith('native/odbc_engine/src/'):
        # transaction/test_helpers.rs is ungated library code, despite its name.
        return 'producao'
    return 'apoio'


def rust_files() -> list[Path]:
    found = []
    for directory, directories, files in os.walk(ROOT / 'native', followlinks=False):
        directories[:] = sorted(d for d in directories if d != 'target'
                                and not d.startswith('.')
                                and not (Path(directory) / d).is_symlink())
        found.extend(Path(directory) / name for name in files
                     if name.endswith('.rs') and not (Path(directory) / name).is_symlink())
    return sorted(found)


def build_inventory(ledger: dict) -> dict:
    records = ledger['reviews']
    rows = []
    for file in rust_files():
        path = file.relative_to(ROOT).as_posix()
        text = source_text(file)
        digest = source_hash(text)
        record = records.get(path)
        stale = bool(record and record['sha256_lf'] != digest)
        if record:
            if record['status'] not in LABELS or record['level'] not in LEVELS:
                raise ValueError(f'Invalid review classification: {path}')
            if (record['status'] == 'nao_revisado') != (record['level'] == 'none'):
                raise ValueError(f'Inconsistent status and evidence level: {path}')
            if not record['scope'].strip():
                raise ValueError(f'Missing review scope: {path}')
            for evidence in record.get('evidence', []):
                if not (ROOT / evidence).is_file():
                    raise ValueError(f'Missing evidence: {evidence}')
            if record['status'] == 'integral':
                required = {'responsibilities', 'contracts', 'errors', 'ownership_unsafe', 'validation'}
                if not all(record.get('checklist', {}).get(key) is True for key in required):
                    raise ValueError(f'Incomplete full-review checklist: {path}')
        kind = category(path)
        rows.append({
            'path': path,
            'category': kind,
            'area': path.split('/')[3] if kind == 'producao' else kind,
            'physical_lines': len(text.splitlines()),
            'sha256_lf': digest,
            'status': record['status'] if record and not stale else 'nao_revisado',
            'level': record['level'] if record and not stale else 'none',
            'stale_review': stale,
            'scope': record['scope'] if record else ledger.get('context_only', {}).get(
                path, 'Sem registro de revisão nesta campanha.'),
            'evidence': record.get('evidence', []) if record else [],
        })
    missing = set(records) - {row['path'] for row in rows}
    if missing:
        raise ValueError(f'Review records refer to missing Rust files: {sorted(missing)}')
    production = [row for row in rows if row['category'] == 'producao']
    counts = Counter(row['status'] for row in production)
    total = len(production)
    validated = sum(row['level'] == 'targeted_validation' for row in production)
    return {
        'schema_version': 1,
        'review_date': ledger['review_date'],
        'basis': ledger['basis'],
        'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'summary': {
            'rust_files': len(rows), 'production_files': total,
            'support_files': len(rows) - total,
            'production_status_counts': {key: counts[key] for key in LABELS},
            'targeted_validated_files': validated,
            'full_review_percent': round(100 * counts['integral'] / total, 4) if total else 0,
            'review_reach_percent': round(100 * (counts['integral'] + counts['parcial']) / total, 4) if total else 0,
            'targeted_validated_percent': round(100 * validated / total, 4) if total else 0,
        },
        'files': rows,
    }


def link(path: str) -> str:
    return f'[{path}](../../{path})'


def render(inventory: dict) -> str:
    summary = inventory['summary']
    total = summary['production_files']
    counts = summary['production_status_counts']
    rows = inventory['files']
    reached = counts['integral'] + counts['parcial']
    out = [
        '# Inventário de revisão Rust', '',
        f"Registro da campanha: **{inventory['review_date']}**. Base Git: `{inventory['git_head']}`.",
        'O inventário representa a árvore de trabalho, incluindo alterações ainda não commitadas.',
        'Os hashes por arquivo identificam o conteúdo avaliado; o commit sozinho não representa esse conteúdo.', '',
        '## Critério e limites', '',
        '- Unidade auditável: um arquivo `.rs` da biblioteca em `native/odbc_engine/src/`, incluindo `lib.rs` e `mod.rs`.',
        '- Todos os arquivos são contados independentemente da feature ou plataforma. Módulos inline não viram unidades adicionais.',
        '- Arquivos dedicados a testes (`tests/`, `tests.rs`, `*_test.rs`, `*_tests.rs`) ficam no inventário de apoio.',
        '- `engine/transaction/test_helpers.rs` integra o denominador: é declarado sem `cfg(test)`, apesar do nome.',
        '- Build scripts, benchmarks, exemplos e a crate de modelos Loom ficam separados. Diretórios ocultos, `target/` e links simbólicos são excluídos.',
        '- **Integral:** registro explícito da revisão do arquivo inteiro, com responsabilidades, contratos, erros, ownership/unsafe e validação pertinente documentados.',
        '- **Parcial:** revisão focal ou triagem de trechos identificados. Não recebe peso arbitrário de 50% e não significa que o restante do arquivo foi auditado.',
        '- **Não revisado:** ausência de evidência registrada nesta campanha, ou registro invalidado por mudança de conteúdo. Não afirma que ninguém revisou esse código em outro momento.',
        '- Listar arquivos, consultar tipos/imports, executar testes ou conferir exportações FFI não concede revisão automática aos módulos.',
        '- As revisões anteriores foram focais. Nenhum módulo de produção tem registro suficiente para ser declarado integralmente revisado.',
        '- Linhas físicas incluem comentários e testes inline; servem apenas para dimensionamento. Não são usadas como percentual de código revisado.', '',
        '## Percentuais defensáveis', '',
        '| Medida | Cálculo | Resultado |', '| --- | --- | ---: |',
        f"| Revisão integral documentada | {counts['integral']} / {total} | {summary['full_review_percent']:.2f}% |",
        f"| Alcance da revisão, incluindo parciais | {reached} / {total} | {summary['review_reach_percent']:.2f}% |",
        f"| Revisão focal com testes/benchmarks específicos | {summary['targeted_validated_files']} / {total} | {summary['targeted_validated_percent']:.2f}% |", '',
        '**O percentual de alcance mede arquivos com algum trecho revisado, não a fração de lógica integralmente auditada.**',
        'Não há rastreabilidade suficiente de cada linha, função ou ramo para calcular esse segundo percentual sem inventar pesos.', '',
        f"Total: **{summary['rust_files']} arquivos Rust**, sendo **{total} de produção** e **{summary['support_files']} de apoio**.", '',
        '## Resumo por área de produção', '',
        '| Área | Arquivos | Integral | Parcial | Não revisado |', '| --- | ---: | ---: | ---: | ---: |',
    ]
    production = [row for row in rows if row['category'] == 'producao']
    for area in sorted({row['area'] for row in production}):
        group = [row for row in production if row['area'] == area]
        status = Counter(row['status'] for row in group)
        out.append(f"| `{area}` | {len(group)} | {status['integral']} | {status['parcial']} | {status['nao_revisado']} |")
    out += ['', '## Escopos efetivamente registrados', '',
            'As referências de teste sustentam somente o escopo descrito; aprovação da suíte completa não amplia esse escopo.', '']
    for row in rows:
        if row['status'] == 'nao_revisado' and not row['stale_review']:
            continue
        out += [f"### `{row['path']}`", '',
                f"Estado: **{LABELS[row['status']]}**. Evidência: {LEVELS[row['level']]}. Categoria: {row['category']}.", '',
                row['scope'], '']
        if row['stale_review']:
            out += ['Registro desatualizado: o hash mudou; a revisão precisa ser reavaliada.', '']
        if row['evidence']:
            out += ['Referências: ' + ', '.join(link(path) for path in row['evidence']) + '.', '']
    out += ['## Como manter este registro', '',
            'A fonte de decisões é [rust_review_ledger.json](rust_review_ledger.json). O relatório e o',
            '[inventário completo em JSON](rust_review_inventory.json) são gerados, sem promover estados automaticamente.',
            'Cada decisão contém escopo, nível de evidência e SHA-256 do texto com quebras de linha normalizadas para LF.',
            'Se um arquivo mudar, seu estado efetivo passa a não revisado até reavaliação explícita. Arquivos novos também começam nesse estado.', '',
            '```powershell', 'python scripts/inventory_rust_review.py', 'python scripts/inventory_rust_review.py --check', '```', '',
            'Atualizar o hash no ledger exige reavaliar o escopo registrado; regenerar o relatório não substitui revisão.', '',
            '## Inventário completo de produção', '',
            '| Arquivo/unidade | Estado | Nível | Linhas físicas |', '| --- | --- | --- | ---: |']
    for row in production:
        out.append(f"| {link(row['path'])} | {LABELS[row['status']]} | {LEVELS[row['level']]} | {row['physical_lines']} |")
    out += ['', '## Inventário de apoio — fora do denominador do motor', '',
            '| Arquivo | Categoria | Estado | Linhas físicas |', '| --- | --- | --- | ---: |']
    for row in rows:
        if row['category'] != 'producao':
            out.append(f"| {link(row['path'])} | {row['category']} | {LABELS[row['status']]} | {row['physical_lines']} |")
    return '\n'.join(out) + '\n'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check snapshot without writing')
    args = parser.parse_args()
    inventory = build_inventory(json.loads(LEDGER.read_text(encoding='utf-8')))
    outputs = {SNAPSHOT: json.dumps(inventory, ensure_ascii=False, indent=2) + '\n', REPORT: render(inventory)}
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or source_text(path) != content:
                raise SystemExit(f'Outdated inventory: {path.relative_to(ROOT)}; run scripts/inventory_rust_review.py')
        else:
            path.write_text(content, encoding='utf-8', newline='\n')
    print(json.dumps(inventory['summary'], ensure_ascii=False))


if __name__ == '__main__':
    main()
