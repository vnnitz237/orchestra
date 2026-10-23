import os
import re
import logging
from github import Github, GithubException

logger = logging.getLogger(__name__)

def _get_gh():
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token or token.startswith("ghp_YOUR"):
        return None
    return Github(token)

def slug(text: str) -> str:
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')[:40]

def read_repo_context(github_repo: str, max_chars: int = 3000) -> str:
    gh = _get_gh()
    if not gh or not github_repo:
        return ""
    try:
        repo = gh.get_repo(github_repo)
        contents = repo.get_contents("")
        file_list = []
        for c in sorted(contents, key=lambda x: (x.type != 'dir', x.path)):
            icon = "DIR" if c.type == "dir" else "FILE"
            file_list.append(f"  {icon}  {c.path}")
            if len(file_list) >= 40:
                break

        readme_text = ""
        try:
            readme = repo.get_readme()
            readme_text = readme.decoded_content.decode('utf-8', errors='replace')[:1500]
        except Exception:
            pass

        ctx = f"GitHub Repository: {github_repo}\n\nFile structure:\n" + "\n".join(file_list)
        if readme_text:
            ctx += f"\n\nREADME (first 1500 chars):\n{readme_text}"
        return ctx[:max_chars]
    except Exception as e:
        logger.warning(f"read_repo_context {github_repo}: {e}")
        return f"(Could not read repo {github_repo}: {e})"

def create_pr(github_repo: str, branch_name: str, title: str, body: str, files: list) -> str:
    """
    Create branch, commit files, open PR. Returns PR HTML URL.
    files: list of {"path": str, "content": str}
    """
    gh = _get_gh()
    if not gh:
        raise ValueError("GITHUB_TOKEN not configured or invalid")

    repo = gh.get_repo(github_repo)
    default_branch = repo.default_branch
    base_sha = repo.get_branch(default_branch).commit.sha

    try:
        repo.create_git_ref(f"refs/heads/{branch_name}", base_sha)
    except GithubException as e:
        if e.status != 422:
            raise

    for f in files:
        path, content = f["path"], f["content"]
        try:
            existing = repo.get_contents(path, ref=branch_name)
            repo.update_file(path, f"orchestra: {title}", content, existing.sha, branch=branch_name)
        except GithubException:
            repo.create_file(path, f"orchestra: {title}", content, branch=branch_name)

    pr = repo.create_pull(title=title, body=body, head=branch_name, base=default_branch)
    return pr.html_url
