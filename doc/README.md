# Documentation - ODBC Fast

Index of all project documentation.

## Build & mustlopment

| Document             | Description                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------- |
| [BUILD.md](BUILD.md) | Complete guide for building and mustloping (Rust + Dart, prerequisites, FFI, troubleshooting) |

## Release & Deployment

| Document                                       | Description                                                                |
| ---------------------------------------------- | -------------------------------------------------------------------------- |
| [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) | Automated release pipeline, GitHub Actions workflow, publishing to pub.dev |

## Troubleshooting

| Document                                 | Description                                                            |
| ---------------------------------------- | ---------------------------------------------------------------------- |
| [OBSERVABILITY.md](OBSERVABILITY.md)     | OTLP telemetry, fallback to ConsoleExporter, ODBC metrics              |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common issues and solutions for mustlopment, build, runtime, and CI/CD |

## Governance

| Document                               | Description                                                         |
| -------------------------------------- | ------------------------------------------------------------------- |
| [api_governance.md](api_governance.md) | Versioning (API, Protocol, ABI), compatibility policy, LTS strategy |

## Future Implementations

| Document                                               | Description                                                                                                              |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| [FUTURE_IMPLEMENTATIONS.md](FUTURE_IMPLEMENTATIONS.md) | Items documented and left for future implementation: parallel bulk insert, Schema PK/FK/Indexes, global queryTimeout |

## Additional Resources

- **Rust engine architecture**: `native/odbc_engine/ARCHITECTURE.md`
- **FFI overview**: `native/doc/` (when available)
- **Main README**: `../README.md`
- **Examples index**: [example/README.md](../example/README.md)

## Quick Links

### For Users

- [Installation Guide](../README.md#installation)
- [Quick Start](../README.md#quick-start)
- [API Documentation](https://pub.dev/documentation/odbc_fast/latest/)

### For Contributors

- [BUILD.md](BUILD.md) - Set up mustlopment environment
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Solve common issues
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) - Understand the release process

### For Maintainers

- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) - Create a new release
- [api_governance.md](api_governance.md) - Versioning and compatibility policies



