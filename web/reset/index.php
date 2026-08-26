<?php

http_response_code(404);
require_once($_SERVER['DOCUMENT_ROOT'].'/error/404/index.html');
exit;
