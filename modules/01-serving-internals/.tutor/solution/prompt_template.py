"""Prompt layout for a document-QA assistant (task 1.4): stable content first, volatile content last."""


def build_messages(system, doc, question, now, request_id):
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": f"{doc}\n\nQuestion: {question}\n(asked at {now}, request {request_id})"},
    ]
