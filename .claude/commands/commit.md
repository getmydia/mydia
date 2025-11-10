# Smart Commit Command

Review the current git changes and create well-organized commits using conventional commit standards.

## Your Task

1. **Analyze Changes**: Review `git status` and `git diff` to understand all modified and untracked files

2. **Group Logically**: Organize changes into logical groups based on:
   - Feature area (e.g., downloads, auth, UI, config)
   - Type of change (e.g., fix, feat, refactor, docs, test, chore)
   - Related functionality (changes that work together)

3. **Create Conventional Commits**: For each group, create a commit following the format:
   ```
   <type>[optional scope]: <description>

   [optional body explaining the why and context]
   ```

   **Common types**:
   - `feat`: New feature
   - `fix`: Bug fix
   - `refactor`: Code change that neither fixes a bug nor adds a feature
   - `docs`: Documentation only changes
   - `style`: Code style/formatting changes
   - `test`: Adding or updating tests
   - `chore`: Maintenance tasks, dependency updates, config changes
   - `perf`: Performance improvements

   **Scope examples**: `downloads`, `auth`, `ui`, `api`, `config`, `docker`, etc.

4. **Present Plan**: Before creating any commits, show me:
   - What groups you've identified
   - What files go in each commit
   - The proposed commit message for each
   - Ask if I want to proceed or adjust

5. **Execute**: After I approve, create the commits using git add and git commit

## Guidelines

- Keep commits focused and atomic (one logical change per commit)
- Write clear, concise commit messages (50 chars or less for subject)
- Use present tense ("add feature" not "added feature")
- Don't commit unrelated changes together
- Look at recent commit history (`git log --oneline -10`) to match the style
- If there are many small changes of the same type, you can combine them into one commit

## Example Output

```
I found 15 changed files. Here's how I propose to group them:

**Commit 1: fix(downloads): resolve NZBGet filename and routing issues**
Files: lib/mydia/downloads/client/nzbget.ex, lib/mydia/downloads.ex
- Fixes NZBGet to use release title instead of "upload.nzb"
- Fixes download client routing to send NZBs to usenet clients

**Commit 2: feat(auth): improve OIDC configuration and compatibility**
Files: lib/mydia_web/controllers/auth_controller.ex, config/config.exs, docs/OIDC_TESTING.md
- Updates OIDC configuration for broader provider compatibility
- Improves error handling and documentation

**Commit 3: chore: update dependencies and configuration**
Files: mix.exs, mix.lock, config/runtime.exs
- Updates mix dependencies to latest versions
- Refines runtime configuration

Proceed with these commits? [yes/no/adjust]
```
