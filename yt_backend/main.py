from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, FileResponse
from fastapi.background import BackgroundTasks
import yt_dlp
import io
import urllib.parse
import subprocess
import zipfile
import json
import os
import asyncio
import uuid

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["Content-Disposition"]
)

# Түр хугацаанд файл хадгалах хавтас
TEMP_DIR = "temp_downloads"
os.makedirs(TEMP_DIR, exist_ok=True)

@app.get("/playlist")
def get_playlist(url: str):
    if not url:
        raise HTTPException(status_code=400, detail="Playlist URL шаардлагатай")
    ydl_opts = {'extract_flat': True, 'skip_download': True}
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if 'entries' not in info:
                raise HTTPException(status_code=400, detail="Энэ плэйлист линк биш байна")
            videos = []
            for entry in info['entries']:
                if entry:
                    videos.append({
                        "id": entry.get("id"),
                        "title": entry.get("title"),
                        "duration": entry.get("duration"),
                        "url": f"https://www.youtube.com/watch?v={entry.get('id')}"
                    })
            return {"playlistTitle": info.get("title"), "totalVideos": len(videos), "videos": videos}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Алдаа гарлаа: {str(e)}")

# 🔥 1. Татах явцыг Фронт руу Real-time мэдээлэх SSE (Server-Sent Events) Endpoint
@app.get("/download-progress")
def download_progress(ids: str, format: str):
    video_ids = ids.split(",")
    ext = "mp3" if format == 'mp3' else "mp4"
    
    async def event_generator():
        total_videos = len(video_ids)
        # uuid4() нь хэзээ ч давтагдахгүй 'c9a646d3-9c61-4cd8...' гэсэн ID үүсгэх тул формат солиход хэзээ ч алдаа гарахгүй
        unique_id = str(uuid.uuid4())[:8] # Богинохон байлгах үүднээс эхний 8 тэмдэгтийг авна
        zip_filename = f"playlist_{format}_{unique_id}.zip"
        zip_path = os.path.join(TEMP_DIR, zip_filename)
        
        # Анхны холболт үүссэнийг мэдээлнэ
        yield f"data: {json.dumps({'status': 'start', 'message': 'Бэкэнд ажиллаж эхэллээ...', 'progress': 0.0})}\n\n"
        await asyncio.sleep(0.1)

        try:
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zip_file:
                for index, v_id in enumerate(video_ids):
                    current_count = index + 1
                    url = f"https://www.youtube.com/watch?v={v_id}"
                    
                    # Нэр шүүх
                    try:
                        with yt_dlp.YoutubeDL({'skip_download': True, 'quiet': True}) as ydl:
                            info = ydl.extract_info(url, download=False)
                            title = info.get('title', v_id).replace('"', '').replace('/', '_')
                    except Exception:
                        title = v_id

                    # Фронт руу аль дууг татаж байгааг илгээнэ
                    prog_percent = (index / total_videos) * 0.9  # Таталт 90% хүртэл явна
                    yield f"data: {json.dumps({'status': 'downloading', 'message': f'({current_count}/{total_videos}) - {title} татаж байна...', 'progress': prog_percent})}\n\n"
                    await asyncio.sleep(0.1)

                    # yt-dlp ажиллуулах
                    cmd = ['yt-dlp', '-o', '-', '--quiet', '--no-playlist', url]
                    cmd += ['-f', 'bestaudio'] if format == 'mp3' else ['-f', 'best[ext=mp4]/best']
                    
                    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    
                    file_buffer = io.BytesIO()
                    while True:
                        # Асинхрон байдлаар уншихын тулд жижиг delay өгнө
                        chunk = process.stdout.read(1024 * 256)
                        if not chunk:
                            break
                        file_buffer.write(chunk)
                    
                    process.terminate()
                    
                    # ZIP руу хийх
                    zip_file.writestr(f"{title}.{ext}", file_buffer.getvalue())
                    file_buffer.close()

            # Архивыг хааж, бэлэн болсныг мэдээлэх (100%)
            yield f"data: {json.dumps({'status': 'completed', 'message': 'ZIP архив бэлэн боллоhe!', 'progress': 1.0, 'file_id': zip_filename})}\n\n"
        
        except Exception as e:
            yield f"data: {json.dumps({'status': 'error', 'message': f'Алдаа гарлаа: {str(e)}'})}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")

# 🔥 ШИНЭЧЛЭГДСЭН БЭКЭНД API: Хоёр өөр форматыг нэг ZIP-д цуглуулж баглах хэсэг
@app.get("/download-progress-v2")
def download_progress_v2(mp3_ids: str = "", mp4_ids: str = ""):
    mp3_list = mp3_ids.split(",") if mp3_ids else []
    mp4_list = mp4_ids.split(",") if mp4_ids else []
    
    # Сонгогдсон нийт таталтын даалгавруудыг тоолно
    total_tasks = len(mp3_list) + len(mp4_list)
    if total_tasks == 0:
        raise HTTPException(status_code=400, detail="Ямар ч файл сонгогдоогүй байна")

    async def event_generator():
        current_task_index = 0
        unique_id = str(uuid.uuid4())[:8]
        zip_filename = f"playlist_bundle_{unique_id}.zip"
        zip_path = os.path.join(TEMP_DIR, zip_filename)
        
        yield f"data: {json.dumps({'status': 'start', 'message': 'Бэкэнд архив үүсгэж эхэллээ...', 'progress': 0.0})}\n\n"
        await asyncio.sleep(0.1)

        try:
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zip_file:
                # 1. Сонгогдсон БҮХ MP3 дуунуудыг татах хэсэг
                for v_id in mp3_list:
                    current_task_index += 1
                    url = f"https://www.youtube.com/watch?v={v_id}"
                    title = v_id
                    try:
                        with yt_dlp.YoutubeDL({'skip_download': True, 'quiet': True}) as ydl:
                            info = ydl.extract_info(url, download=False)
                            title = info.get('title', v_id).replace('"', '').replace('/', '_')
                    except Exception:
                        pass

                    prog_percent = (current_task_index / total_tasks) * 0.95
                    yield f"data: {json.dumps({'status': 'downloading', 'message': f'({current_task_index}/{total_tasks}) - [MP3] {title} татаж байна...', 'progress': prog_percent})}\n\n"
                    await asyncio.sleep(0.05)

                    cmd = ['yt-dlp', '-o', '-', '--quiet', '--no-playlist', '-f', 'bestaudio', url]
                    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    
                    file_buffer = io.BytesIO()
                    while True:
                        chunk = process.stdout.read(1024 * 256)
                        if not chunk: break
                        file_buffer.write(chunk)
                    process.terminate()
                    
                    zip_file.writestr(f"{title}.mp3", file_buffer.getvalue())
                    file_buffer.close()

                # 2. Сонгогдсон БҮХ MP4 дүрс бичлэгүүдийг татах хэсэг
                for v_id in mp4_list:
                    current_task_index += 1
                    url = f"https://www.youtube.com/watch?v={v_id}"
                    title = v_id
                    try:
                        with yt_dlp.YoutubeDL({'skip_download': True, 'quiet': True}) as ydl:
                            info = ydl.extract_info(url, download=False)
                            title = info.get('title', v_id).replace('"', '').replace('/', '_')
                    except Exception:
                        pass

                    prog_percent = (current_task_index / total_tasks) * 0.95
                    yield f"data: {json.dumps({'status': 'downloading', 'message': f'({current_task_index}/{total_tasks}) - [MP4] {title} татаж байна...', 'progress': prog_percent})}\n\n"
                    await asyncio.sleep(0.05)

                    cmd = ['yt-dlp', '-o', '-', '--quiet', '--no-playlist', '-f', 'best[ext=mp4]/best', url]
                    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    
                    file_buffer = io.BytesIO()
                    while True:
                        chunk = process.stdout.read(1024 * 256)
                        if not chunk: break
                        file_buffer.write(chunk)
                    process.terminate()
                    
                    zip_file.writestr(f"{title}.mp4", file_buffer.getvalue())
                    file_buffer.close()

            # Бүх ажил дуусахад 100% болгоно
            yield f"data: {json.dumps({'status': 'completed', 'message': 'Бүх дууг ZIP архивт амжилттай баглалаа!', 'progress': 1.0, 'file_id': zip_filename})}\n\n"
        
        except Exception as e:
            yield f"data: {json.dumps({'status': 'error', 'message': f'Алдаа гарлаа: {str(e)}'})}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")

# 🔥 2. Бэлэн болсон ZIP файлыг хэрэглэгч рүү илгээгээд, дараа нь устгах API
@app.get("/fetch-file/{file_id}")
def fetch_file(file_id: str, background_tasks: BackgroundTasks):
    file_path = os.path.join(TEMP_DIR, file_id)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="Файл олдсонгүй")
    
    # Файл татагдаж дууссаны дараа серверээс устгах Background Task нэмэх
    def remove_file():
        try:
            os.remove(file_path)
        except Exception as e:
            print(f"Error deleting temp file: {e}")
            
    background_tasks.add_task(remove_file)
    
    return FileResponse(
        file_path, 
        media_type="application/zip", 
        filename=urllib.parse.quote(f"youtube_playlist.zip")
    )