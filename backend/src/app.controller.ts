import { Controller, Get } from '@nestjs/common';
import { AppService } from './app.service';

@Controller('api')
export class AppController {
  constructor(private readonly appService: AppService) {}

  @Get('hello')
  getHello(): { message: string } {
    console.log('Hello API가 호출되었습니다!');
    return this.appService.getHello();
  }
}
