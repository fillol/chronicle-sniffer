# processor/Dockerfile - Immagine per il Processore Cloud Run

# Usa un'immagine base Python slim
FROM python:3.9-slim

# Installa tshark
RUN apt-get update && apt-get install -y --no-install-recommends \
    tshark \
    && rm -rf /var/lib/apt/lists/*

# Installa dipendenze Python
# Copia prima requirements.txt per caching layer Docker
COPY processor/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Crea directory di lavoro
WORKDIR /app

# Copia il codice dell'applicazione
COPY processor/processor_app.py .
COPY processor/json2udm_cloud.py .

# Imposta logging non bufferizzato per Cloud Logging
ENV PYTHONUNBUFFERED=1

# Comando per avviare l'applicazione con Gunicorn
# Ascolta sulla porta 8080 (default Cloud Run)
# Timeout aumentato per elaborazione pcap
CMD exec gunicorn --bind :${PORT:-8080} --workers 1 --threads 8 --timeout 600 processor_app:app
