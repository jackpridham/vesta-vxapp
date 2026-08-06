#!/usr/bin/env python3
import json, os, socket, struct, subprocess, tempfile, threading

repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
helper = os.path.join(repo, "func/vx/compose/probe-exec.py")
root = tempfile.mkdtemp(prefix="vx-probe-engine.")
sock_path = os.path.join(root, "engine.sock")
requests = []

def response(conn, status, body=b"", content_type=b"application/json"):
    conn.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Type: " + content_type +
                 b"\r\nContent-Length: " + str(len(body)).encode() +
                 b"\r\nConnection: close\r\n\r\n" + body)

def server():
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(sock_path); listener.listen(3)
    for index in range(3):
        conn, _ = listener.accept(); data = b""
        while b"\r\n\r\n" not in data: data += conn.recv(4096)
        head, body = data.split(b"\r\n\r\n", 1)
        length = 0
        for line in head.split(b"\r\n")[1:]:
            if line.lower().startswith(b"content-length:"): length = int(line.split(b":",1)[1])
        while len(body) < length: body += conn.recv(4096)
        requests.append((head.split(b"\r\n",1)[0].decode(), body[:length]))
        if index == 0:
            response(conn, b"201 Created", json.dumps({"Id":"b"*64}).encode())
        elif index == 1:
            stdout=b'{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}\n'
            stderr=b"bounded diagnostic"
            frames=b"\x01\0\0\0"+struct.pack(">I",len(stdout))+stdout+b"\x02\0\0\0"+struct.pack(">I",len(stderr))+stderr
            response(conn,b"200 OK",frames,b"application/vnd.docker.raw-stream")
        else:
            response(conn,b"200 OK",json.dumps({"Running":False,"ExitCode":0,"Pid":0}).encode())
        conn.close()
    listener.close()

thread=threading.Thread(target=server); thread.start()
request_path=os.path.join(root,"request.json"); stdout_path=os.path.join(root,"stdout")
stderr_path=os.path.join(root,"stderr"); result_path=os.path.join(root,"result.json")
with open(request_path,"w") as f: json.dump({"container_id":"a"*64,
  "argv":["/usr/local/bin/health","--json"],"timeout_seconds":2,
  "transport_grace_seconds":2,"max_output_bytes":512},f)
env={"PATH":os.environ.get("PATH","/usr/bin:/bin"),"VX_COMPOSE_PROBE_TEST_SOCKET":sock_path}
run=subprocess.run(["/usr/bin/python3",helper,request_path,stdout_path,stderr_path,result_path],env=env)
thread.join(timeout=5)
assert run.returncode == 0
assert requests[0][0] == "POST /v1.41/containers/"+"a"*64+"/exec HTTP/1.1"
create=json.loads(requests[0][1]); assert create == {"AttachStdin":False,"AttachStdout":True,"AttachStderr":True,"Tty":False,"Cmd":["/usr/local/bin/health","--json"]}
assert requests[1][0] == "POST /v1.41/exec/"+"b"*64+"/start HTTP/1.1"
assert json.loads(requests[1][1]) == {"Detach":False,"Tty":False}
assert requests[2][0] == "GET /v1.41/exec/"+"b"*64+"/json HTTP/1.1"
assert open(stdout_path,"rb").read().endswith(b"\n")
assert open(stderr_path,"rb").read() == b"bounded diagnostic"
result=json.load(open(result_path)); assert result["EXEC_ID"] == "b"*64 and result["RUNNING"] is False and result["EXIT_CODE"] == 0
print("PASS: probe Engine API helper")
