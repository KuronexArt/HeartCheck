FROM python:3.12-bookworm
RUN pip install --no-cache-dir pymobiledevice3 \
 && curl -fL -o /usr/local/bin/plumesign https://github.com/claration/impactor/releases/download/v2.7.3/plumesign-linux-x86_64 \
 && chmod +x /usr/local/bin/plumesign
ENV TZ=Asia/Seoul PYTHONUNBUFFERED=1 RUST_LOG=info
WORKDIR /data
COPY refresh.py /app/refresh.py
CMD ["python", "/app/refresh.py"]
