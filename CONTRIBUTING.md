# Contributing to Windows-WIM-Patchning

We welcome contributions! Please follow these guidelines:

## How to Submit an Issue or Bug Report

1. Check existing issues to see if your problem has already been reported.
2. Open a new issue with a clear title and detailed description of the problem, including steps to reproduce and error messages.

## How to Contribute Code

1. Fork the repository and clone your fork.
2. Create a new feature branch: `git checkout -b feature/my-feature`.
3. Write clear, focused commits with descriptive messages.
4. Ensure PowerShell scripts follow the project's style:
   - Use `Write-Log` for logging.
   - Error handling should use `try/catch` and update `Errors` in run summary.
5. Test your changes locally with both `-DryRun` and a real run.
6. Ensure existing tests (if any) still pass and add tests for new functionality.
7. Push your branch and open a Pull Request against `main`.

## Code Style

- Use PascalCase for function names and parameters.
- Add XML documentation for exported functions.
- Follow PSScriptAnalyzer guidelines.

## Code Reviews

Pull Requests will be reviewed by repository maintainers. Feedback may involve style, tests, or implementation details.

## Security

If you discover a security vulnerability, please disclose it privately by emailing the repository owner before opening a public issue.
