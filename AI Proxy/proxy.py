from flask import Flask, request, Response
import requests
import json

app = Flask(__name__)

UPSTREAM = "https://openrouter.ai"

# ============================================================
# DEBUG
# ============================================================

DEBUG_REQUEST = True
DEBUG_RESPONSE = True


def format_data(data):
    try:
        obj = json.loads(data)
        return json.dumps(obj, indent=2, ensure_ascii=False)
    except (json.JSONDecodeError, TypeError):
        return data.decode("utf-8", errors="replace") if isinstance(data, bytes) else str(data)


def print_request():
    print("\n" + "=" * 70)
    print(">>> REQUEST")
    print("=" * 70)

    print(f"{request.method} {request.full_path}")

    print("\nHeaders:")
    for key, value in request.headers.items():
        # API-ключ в логах не показываем
        if key.lower() == "authorization":
            value = "Bearer ***HIDDEN***"

        print(f"{key}: {value}")

    data = request.get_data()

    if data:
        print("\nBody:")
        print(format_data(data))
    else:
        print("\nBody: <empty>")

    print("=" * 70)


def print_response(response):
    print("\n" + "=" * 70)
    print("<<< RESPONSE")
    print("=" * 70)

    print(f"HTTP {response.status_code}")

    print("\nHeaders:")
    for key, value in response.headers.items():
        print(f"{key}: {value}")

    if response.content:
        print("\nBody:")
        print(format_data(response.content))
    else:
        print("\nBody: <empty>")

    print("=" * 70)


@app.route(
    "/",
    defaults={"path": ""},
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"]
)
@app.route(
    "/<path:path>",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"]
)
def proxy(path):

    if not path:
        path = "api/v1/chat/completions"

    url = f"{UPSTREAM}/{path}"

    if DEBUG_REQUEST:
        print_request()

    headers = {
        k: v for k, v in request.headers
        if k.lower() != "host"
    }

    try:
        response = requests.request(
            method=request.method,
            url=url,
            headers=headers,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            timeout=120,
            verify=True
        )

        if DEBUG_RESPONSE:
            print_response(response)

        # Не передаем hop-by-hop заголовки
        excluded_headers = {
            "content-encoding",
            "content-length",
            "transfer-encoding",
            "connection",
        }

        response_headers = {
            k: v
            for k, v in response.headers.items()
            if k.lower() not in excluded_headers
        }

        return Response(
            response.content,
            status=response.status_code,
            headers=response_headers
        )

    except requests.RequestException as e:

        print(f"\n[PROXY ERROR] {e}")

        return Response(
            f"Proxy Error: {e}",
            status=502
        )


if __name__ == "__main__":
    print("=== OpenRouter local proxy ===")
    print("URL: http://127.0.0.1:5000")
    print(f"DEBUG_REQUEST  = {DEBUG_REQUEST}")
    print(f"DEBUG_RESPONSE = {DEBUG_RESPONSE}")

    app.run(
        host="127.0.0.1",
        port=5000
    )