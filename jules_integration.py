import os
import json
import urllib.request
import urllib.error
import sys

def main():
    # Read environment variables
    api_key = os.environ.get("JULES_API_KEY")
    commit_sha = os.environ.get("GITHUB_COMMIT", "unknown")
    branch_name = os.environ.get("GITHUB_BRANCH", "unknown")
    repo_name = os.environ.get("GITHUB_REPO", "unknown")

    if not api_key:
        print("Error: JULES_API_KEY environment variable is not set.", file=sys.stderr)
        # Avoid printing the key to logs, even if it is somehow partial or malformed.
        sys.exit(1)

    print(f"Preparing to send build metadata for repository: {repo_name}, branch: {branch_name}, commit: {commit_sha}")

    # Construct the JSON payload
    payload = {
        "repository": repo_name,
        "branch": branch_name,
        "commit_sha": commit_sha,
        "build_status": "success", # This script is only run if previous build steps succeed
        "event_type": "build_completed"
    }

    json_data = json.dumps(payload).encode('utf-8')

    # Replace with the actual Jules API endpoint if different.
    # We use a placeholder URL for this setup.
    url = "https://api.jules.ai/v1/integrations/github/build_status"

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    req = urllib.request.Request(url, data=json_data, headers=headers, method='POST')

    try:
        with urllib.request.urlopen(req) as response:
            status_code = response.getcode()
            response_body = response.read().decode('utf-8')

            if status_code in (200, 201, 202):
                print(f"Successfully sent build metadata to Jules API. Status code: {status_code}")
                # Optional: print(response_body) if debugging is needed, but ensure no sensitive data is printed
            else:
                print(f"Warning: Jules API returned an unexpected status code: {status_code}", file=sys.stderr)
                print(f"Response: {response_body}", file=sys.stderr)
                # Don't fail the build if the integration notification fails, unless explicitly required.

    except urllib.error.HTTPError as e:
        print(f"HTTP Error failed to send to Jules API: {e.code} - {e.reason}", file=sys.stderr)
        response_body = e.read().decode('utf-8')
        print(f"Response: {response_body}", file=sys.stderr)
    except urllib.error.URLError as e:
        print(f"URL Error failed to send to Jules API: {e.reason}", file=sys.stderr)
    except Exception as e:
        print(f"An unexpected error occurred: {str(e)}", file=sys.stderr)

if __name__ == "__main__":
    main()
