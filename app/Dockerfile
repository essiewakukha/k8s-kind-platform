FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY app.py .
# Numeric user so Kubernetes can verify runAsNonRoot
USER 65534:65534
EXPOSE 8080
CMD ["python", "app.py"]