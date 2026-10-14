<?php

require_once __DIR__ . '/config/env.php';

$host = env('DB_HOST');
$port = env('DB_PORT', '5432');
$dbname = env('DB_NAME');
$user = env('DB_USER');
$pass = env('DB_PASS');
$sslmode = env('DB_SSLMODE', 'require');

$endpoint = explode('.', $host)[0];

$dsn = "pgsql:host={$host};port={$port};dbname={$dbname};sslmode={$sslmode};options='endpoint={$endpoint}'";

try {
    $pdo = new PDO($dsn, $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);

    echo "DATABASE CONNECTION SUCCESSFUL!";
} catch (PDOException $e) {
    echo "DATABASE CONNECTION FAILED<br><br>";
    echo "ERROR: " . htmlspecialchars($e->getMessage());
}