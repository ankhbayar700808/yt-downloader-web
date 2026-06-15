# --- Алхам 1: Flutter ашиглан вэб хувилбарыг build хийх ---
FROM ghcr.io/cirruslabs/flutter:3.22.0 AS build-env

WORKDIR /app

# Төслийн файлуудыг хуулах
COPY . .

# Flutter веб файлыг бэлдэх
RUN flutter doctor
RUN flutter build web --release

# --- Алхам 2: Бэлэн болсон вэбийг Nginx сервер дээр асаах ---
FROM nginx:alpine

# Flutter-ийн build хийсэн бэлэн файлуудыг Nginx-ийн хавтас руу зөөх
COPY --from=build-env /app/build/web /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
