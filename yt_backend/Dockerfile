# Python 3.11 суурьтай хөнгөн линукс ашиглана
FROM python:3.11-slim

# Системд yt-dlp-д шаардлагатай ffmpeg болон бусад сангуудыг суулгах
RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Шаардлагатай сангуудыг суулгах
RUN pip install --no-cache-dir fastapi uvicorn yt-dlp

# Кодоо хуулах
COPY . .

# Түр хадгалах хавтас үүсгэх
RUN mkdir -p temp_downloads

EXPOSE 5000

# Серверийг асаах
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
