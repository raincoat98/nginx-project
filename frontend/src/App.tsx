import { useState, useEffect } from "react";
import "./App.css";

function App() {
  const [message, setMessage] = useState<string>("");
  const [isLoading, setIsLoading] = useState<boolean>(false);

  const handleClick = async () => {
    try {
      setIsLoading(true);

      // 현재 URL을 기준으로 API 호출 (Nginx를 통해 프록시)
      // 브라우저의 현재 호스트를 사용하여 상대 경로로 호출
      const apiPath = "/api/hello";

      const response = await fetch(apiPath, {
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
        },
      });

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }

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

  // 컴포넌트 마운트 시 자동 호출
  useEffect(() => {
    handleClick();
  }, []);

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
