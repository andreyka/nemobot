FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /opt/openclaw-worker-bridge

COPY worker-bridge.py /opt/openclaw-worker-bridge/app.py

EXPOSE 8080

ENTRYPOINT ["python", "/opt/openclaw-worker-bridge/app.py"]
