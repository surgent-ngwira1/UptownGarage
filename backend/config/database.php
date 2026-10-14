<?php
require_once __DIR__ . '/env.php';

class Database
{
    private static ?PDO $instance = null;

    public static function connect(): PDO
    {
        if (self::$instance !== null) {
            return self::$instance;
        }

        $host = env('DB_HOST');
        $port = env('DB_PORT', '5432');
        $dbname = env('DB_NAME');
        $user = env('DB_USER');
        $pass = env('DB_PASS');
        $sslmode = env('DB_SSLMODE', 'require');

        $endpoint = explode('.', $host)[0];

$dsn = "pgsql:host={$host};port={$port};dbname={$dbname};sslmode={$sslmode};options='endpoint={$endpoint}'";

        try {
            self::$instance = new PDO($dsn, $user, $pass, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,C:\xampp\php\php.exe -S localhost:8000
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => true,
            ]);
        } catch (PDOException $e) {
            http_response_code(500);
            echo json_encode([
                'success' => false,
                'message' => 'Database connection failed.',
                'error' => $e->getMessage()
            ]);
            exit;
        }

        return self::$instance;
    }
}