FROM python:3.13-slim
RUN groupadd --gid 1000 workmate && useradd --uid 1000 --gid 1000 --no-create-home workmate
WORKDIR /app
COPY agent.py /app/agent.py
USER workmate
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
HEALTHCHECK --interval=60s --timeout=5s --start-period=45s --retries=3 CMD ["python", "agent.py", "--healthcheck"]
CMD ["python", "-u", "agent.py"]
