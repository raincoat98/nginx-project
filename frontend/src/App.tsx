import { useState } from "react";
import "./App.css";

function App() {
  const [message, setMessage] = useState<string>("");
  const [isLoading, setIsLoading] = useState<boolean>(false);

  const handleClick = async () => {
    try {
      setIsLoading(true);

      const URL = import.meta.env.VITE_API_URL ?? "http://localhost:4500";

      const response = await fetch(`${URL}/api/hello`, {
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
        },
      });
      const data = await response.json();
      console.log("서버 응답:", data);
      setMessage(data.message);
    } catch (error) {
      console.error("에러 발생:", error);
      setMessage("에러가 발생했습니다.");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="App">
      <header className="App-header">
        <h1>Nginx 프로젝트</h1>
        <button
          onClick={handleClick}
          className="action-button"
          disabled={isLoading}
        >
          {isLoading ? "로딩 중..." : "백엔드 호출하기"}
        </button>
        {message && <p className="message">{message}</p>}
      </header>
    </div>
  );
}

export default App;
