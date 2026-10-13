FROM python:3.11-slim

WORKDIR /app
COPY server.py .
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 3000
CMD ["python", "server.py"]
