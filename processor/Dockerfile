FROM python:3.9-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    tshark \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

WORKDIR /app
COPY processor_app.py .
COPY json2udm_cloud.py .

ENV PYTHONUNBUFFERED=1

CMD exec gunicorn --bind :${PORT:-8080} --workers 1 --threads 8 --timeout 600 processor_app:app