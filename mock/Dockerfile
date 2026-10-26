# aiinfra-mock:1.0 -- course-owned simulators: vllm | dcgm | hf-mirror (role = first argument)
FROM python:3.12-slim
LABEL course=aiinfra
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app HF_HOME=/tmp/hf
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY aimock /app/aimock
COPY bin/ /usr/local/bin/
COPY models /models
RUN chmod +x /usr/local/bin/nvidia-smi /usr/local/bin/dmesg && useradd -u 10001 -m mock && mkdir -p /config /data && chown -R mock /tmp
USER 10001
EXPOSE 8000
ENTRYPOINT ["python", "-m", "aimock"]
