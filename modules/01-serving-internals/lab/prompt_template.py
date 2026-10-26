"""Prompt layout for a document-QA assistant (task 1.4).

build_messages() returns the chat messages sent to the engine for ONE question about a shared document.
The stable part (system prompt + document) is identical for every request; the question, the current time
and the request id change per request.
"""


def build_messages(system, doc, question, now, request_id):
    return [
        {"role": "system", "content": f"Current time: {now}\nRequest id: {request_id}\n{system}"},
        {"role": "user", "content": f"{doc}\n\nQuestion: {question}"},
    ]
