FROM python:3.11-slim
WORKDIR /app
RUN pip install prometheus_client --no-cache-dir
COPY grs_exporter.py /app/grs_exporter.py
EXPOSE 9100
ENV RESULTS_DIR=/results
ENV EXPORTER_PORT=9100
CMD ["python3", "/app/grs_exporter.py"]
